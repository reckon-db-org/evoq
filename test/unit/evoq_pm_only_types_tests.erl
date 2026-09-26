%% @doc A process manager receives every event of its types, correlated to
%% its own instances with their own state, whether or not an event handler
%% consumes the type too (evoq #2), and module-handler registration refuses
%% instead of lying (evoq #3).
%%
%% The store subscription routed an event only when the type registry held a
%% HANDLER for its type, and process managers registered with the PM router
%% only: a type only a process manager declared was dropped at catch-up, at
%% backfill and live. And PM instances were found by event type and process
%% id alone, so two process managers correlating on the same id reached
%% each other's instance.
-module(evoq_pm_only_types_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-define(PLACED, <<"pm_order_placed_v1">>).
-define(PAID, <<"pm_order_paid_v1">>).

%% (a) The process manager is registered before the store subscription
%% starts: catch-up delivers every event of its types, and the state each
%% order's instance has when an event arrives holds that order's earlier
%% events and no other order's.
catch_up_reaches_a_pm_only_type_with_per_process_state_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2), paid(<<"o1">>, 3)]),
        boot(StoreId, [order_pm], [subscription]),
        ?assertEqual([{?PLACED, <<"o1">>, []},
                      {?PLACED, <<"o2">>, []},
                      {?PAID, <<"o1">>, [?PLACED]}],
                     order_pm_seen())
    end).

%% (b) The process manager registers after catch-up: its types are new, so
%% backfill delivers their history.
backfill_reaches_a_late_pm_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2), paid(<<"o1">>, 3)]),
        boot(StoreId, [subscription], [order_pm]),
        ?assertEqual([{?PLACED, <<"o1">>, []},
                      {?PLACED, <<"o2">>, []},
                      {?PAID, <<"o1">>, [?PLACED]}],
                     order_pm_seen())
    end).

%% (c) A live append of a type only the process manager declares reaches its
%% instance for that order.
live_event_reaches_a_pm_only_type_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2)]),
        boot(StoreId, [order_pm], [subscription]),
        evoq_fake_boot_backend:push_live(StoreId, [paid(<<"o2">>, 3)]),
        timer:sleep(300),
        ?assertEqual({?PAID, <<"o2">>, [?PLACED]}, lists:last(order_pm_seen()))
    end).

%% (d) A type a handler and a process manager share still reaches each of
%% them exactly once per event.
a_shared_type_reaches_the_handler_and_the_pm_once_each_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2)]),
        boot(StoreId, [order_pm, placed_handler], [subscription]),
        ?assertEqual([<<"o1">>, <<"o2">>], ns(placed_handler)),
        ?assertEqual([{?PLACED, <<"o1">>, []}, {?PLACED, <<"o2">>, []}], order_pm_seen())
    end).

%% (e) Two process managers correlating on the same id keep their own
%% instances: each is handed the event once, with its own state.
two_pms_on_one_id_keep_their_own_instances_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), paid(<<"o1">>, 2)]),
        boot(StoreId, [order_pm, audit_pm], [subscription]),
        ?assertEqual([{?PLACED, <<"o1">>, []}, {?PAID, <<"o1">>, [?PLACED]}], order_pm_seen()),
        ?assertEqual([{<<"o1">>, #{audit_of => <<"o1">>, count => 0}}],
                     [X || {X, _} <- evoq_replay_probe:calls(audit_pm)])
    end).

%% evoq #3: register_handler/2 and unregister_handler/2 stored nothing and
%% answered ok, so a caller believed a module was registered that would
%% never receive an event. They refuse.
module_handler_registration_refuses_test_() ->
    pm_test(fun() ->
        started(evoq_event_type_registry:start_link()),
        ?assertEqual({error, not_supported},
                     evoq_event_type_registry:register_handler(?PLACED, some_module)),
        ?assertEqual({error, not_supported},
                     evoq_event_type_registry:unregister_handler(?PLACED, some_module))
    end).

%%====================================================================
%% Boot and fixtures
%%====================================================================

pm_test(Fun) ->
    {timeout, 30, fun() -> try Fun() after shutdown() end end}.

fresh_store(Events) ->
    evoq_test_isolation:stop_leftover_evoq(),
    application:set_env(evoq, event_store_adapter, evoq_fake_boot_backend),
    application:set_env(evoq, subscription_adapter, evoq_fake_boot_backend),
    StoreId = list_to_atom("pm_only_store_" ++ integer_to_list(erlang:unique_integer([positive]))),
    evoq_fake_boot_backend:seed(StoreId, Events),
    evoq_fake_boot_backend:reset(StoreId),
    ok = evoq_replay_probe:reset(),
    {ok, _} = application:ensure_all_started(telemetry),
    StoreId.

%% Start the routers, then the First group, settle, then the Then group.
boot(StoreId, First, Then) ->
    lists:foreach(fun(M) -> started(M:start_link()) end,
                  [evoq_event_type_registry, evoq_type_provider,
                   evoq_event_router, evoq_pm_router, evoq_pm_instance_sup]),
    lists:foreach(fun(C) -> start(C, StoreId) end, First),
    timer:sleep(300),
    lists:foreach(fun(C) -> start(C, StoreId) end, Then),
    timer:sleep(300).

start(subscription, StoreId) -> started(evoq_store_subscription:start_link(StoreId));
start(order_pm, _) -> ok = evoq_process_manager:start(evoq_order_probe_pm, #{});
start(audit_pm, _) -> ok = evoq_process_manager:start(evoq_audit_probe_pm, #{});
start(placed_handler, _) ->
    started(evoq_event_handler:start_link(evoq_order_placed_probe_handler, #{})).

started({ok, Pid}) ->
    put(started, [Pid | get_started()]),
    ok.

get_started() ->
    case get(started) of
        undefined -> [];
        Pids -> Pids
    end.

shutdown() ->
    Pids = get_started(),
    erase(started),
    Subs = [P || P <- Pids, is_store_subscription(P)],
    lists:foreach(fun stop/1, Subs ++ (Pids -- Subs)).

is_store_subscription(Pid) ->
    case process_info(Pid, registered_name) of
        {registered_name, Name} -> lists:prefix("evoq_store_sub_", atom_to_list(Name));
        _ -> false
    end.

stop(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

%% What the order process manager handled: {Type, Order, types seen before}.
order_pm_seen() ->
    [{Type, Id, Seen} || {{Type, Id, #{seen := Seen}}, _} <- evoq_replay_probe:calls(order_pm)].

ns(Who) -> [N || {N, _} <- evoq_replay_probe:calls(Who)].

placed(Order, Pos) -> event(?PLACED, Order, Pos).
paid(Order, Pos) -> event(?PAID, Order, Pos).

event(Type, Order, Pos) ->
    #evoq_event{event_id = <<Type/binary, "-", Order/binary>>, event_type = Type,
                stream_id = <<"order-", Order/binary>>, version = Pos,
                data = #{order => Order}, metadata = #{}, tags = undefined,
                timestamp = Pos, epoch_us = Pos}.
