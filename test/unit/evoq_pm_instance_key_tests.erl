%% @doc Process manager instances are their own, and module-handler
%% registration refuses instead of lying.
%%
%% PM instances were found by event type and process id alone, with no PM
%% module in the key, so two process managers correlating on the same id (an
%% order id, say) reached each other's instance and one handled the other's
%% events (found writing the evoq #2 tests). And register_handler/2 stored
%% nothing and answered ok (evoq #3).
-module(evoq_pm_instance_key_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-define(PLACED, <<"pm_order_placed_v1">>).
-define(PAID, <<"pm_order_paid_v1">>).

%% Two process managers correlating on the same id keep their own
%% instances: each is handed its events once, with its own state. (A handler
%% consumes both types so the store subscription routes them.)
two_pms_on_one_id_keep_their_own_instances_test_() ->
    pm_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), paid(<<"o1">>, 2)]),
        boot(StoreId, [order_pm, audit_pm, order_handler], [subscription]),
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
start(order_handler, _) ->
    started(evoq_event_handler:start_link(evoq_order_events_probe_handler, #{})).

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
