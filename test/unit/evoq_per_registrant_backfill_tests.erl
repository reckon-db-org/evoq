%% @doc Every consumer of an event type receives that type's history,
%% however late it registers relative to other consumers of the same type
%% (evoq #4), and a process manager receives every event of its types
%% whether or not an event handler consumes them too (evoq #2).
%%
%% Backfill ran only for a type's FIRST handler, and delivered to whoever
%% was registered while it ran: a second consumer of a type got no history,
%% and a projection on [A, B] registering after a handler on [B] lost the B
%% history entirely. A process manager registered with the PM router only,
%% so a type no handler consumed was never routed at all.
-module(evoq_per_registrant_backfill_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-define(A, <<"restart_a_v1">>).
-define(B, <<"restart_b_v1">>).
-define(PLACED, <<"pm_order_placed_v1">>).
-define(PAID, <<"pm_order_paid_v1">>).

%%====================================================================
%% evoq #4: backfill per registrant
%%====================================================================

%% The issue's own test: H2 registers on a type H1 already holds, after
%% H1's backfill. H2 gets the whole history; H1 gets nothing twice.
a_second_handler_of_a_type_gets_its_history_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store(bs(1, 5)),
        boot(StoreId, [], [subscription]),
        start_late({named_b, h1}),
        start_late({named_b, h2}),
        ?assertEqual([1, 2, 3, 4, 5], ns(h1)),
        ?assertEqual([1, 2, 3, 4, 5], ns(h2))
    end).

%% A projection on [A, B] after a handler on [B]: B was already covered, so
%% only A was backfilled and the projection never saw a B event of history.
a_projection_after_a_handler_on_a_shared_type_gets_every_event_in_order_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store(interleaved(1, 3)),
        boot(StoreId, [], [subscription]),
        start_late({named_b, h}),
        start_late(ab_projection),
        ?assertEqual([{?A, 1}, {?B, 1}, {?A, 2}, {?B, 2}, {?A, 3}, {?B, 3}],
                     ab_projected()),
        ?assertEqual([1, 2, 3], ns(h))
    end).

%% A live event that reaches the subscription before the late handler's
%% backfill runs goes to that handler once, after its history, in order:
%% it is not delivered to a registrant whose history has not been sent.
a_live_event_queued_before_the_backfill_arrives_once_and_in_order_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store(bs(1, 5)),
        boot(StoreId, [], [subscription]),
        Sub = subscription_pid(StoreId),
        ok = sys:suspend(Sub),
        evoq_fake_boot_backend:push_live(StoreId, bs(6, 6)),
        start_now({named_b, h}),
        ok = sys:resume(Sub),
        settle(),
        ?assertEqual([1, 2, 3, 4, 5, 6], ns(h))
    end).

%% A late handler gets the history replayed on the store's own positions,
%% the numbers a projection checkpoints on.
a_backfill_carries_global_positions_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store(interleaved(1, 2)),
        boot(StoreId, [], [subscription]),
        start_late({named_b, h}),
        ?assertEqual([1, 3], [maps:get(global_position, M)
                              || {_, M} <- evoq_replay_probe:calls(h)])
    end).

%%====================================================================
%% evoq #2: types only a process manager consumes
%%====================================================================

%% Catch-up: the process manager is registered before the subscription.
catch_up_reaches_a_pm_only_type_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2), paid(<<"o1">>, 3)]),
        boot(StoreId, [order_pm], [subscription]),
        ?assertEqual([{?PLACED, <<"o1">>, []},
                      {?PLACED, <<"o2">>, []},
                      {?PAID, <<"o1">>, [?PLACED]}],
                     order_pm_seen())
    end).

%% Backfill: the process manager registers after catch-up.
backfill_reaches_a_late_pm_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2), paid(<<"o1">>, 3)]),
        boot(StoreId, [subscription], [order_pm]),
        ?assertEqual([{?PLACED, <<"o1">>, []},
                      {?PLACED, <<"o2">>, []},
                      {?PAID, <<"o1">>, [?PLACED]}],
                     order_pm_seen())
    end).

%% Live: an append of a type only the process manager declares.
live_event_reaches_a_pm_only_type_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2)]),
        boot(StoreId, [order_pm], [subscription]),
        evoq_fake_boot_backend:push_live(StoreId, [paid(<<"o2">>, 3)]),
        settle(),
        ?assertEqual({?PAID, <<"o2">>, [?PLACED]}, lists:last(order_pm_seen()))
    end).

%% A type a handler and a process manager share reaches each once.
a_shared_type_reaches_the_handler_and_the_pm_once_each_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2)]),
        boot(StoreId, [order_pm, placed_handler], [subscription]),
        ?assertEqual([<<"o1">>, <<"o2">>], ns(placed_handler)),
        ?assertEqual([{?PLACED, <<"o1">>, []}, {?PLACED, <<"o2">>, []}], order_pm_seen())
    end).

%% The shape that parked #2 without #4: a handler registering just after a
%% process manager on a shared type still gets the history, and the process
%% manager gets nothing twice.
a_handler_after_a_pm_on_a_shared_type_gets_its_history_test_() ->
    backfill_test(fun() ->
        StoreId = fresh_store([placed(<<"o1">>, 1), placed(<<"o2">>, 2)]),
        boot(StoreId, [subscription], [order_pm, placed_handler]),
        ?assertEqual([<<"o1">>, <<"o2">>], ns(placed_handler)),
        ?assertEqual([{?PLACED, <<"o1">>, []}, {?PLACED, <<"o2">>, []}], order_pm_seen())
    end).

%%====================================================================
%% Boot and fixtures
%%====================================================================

backfill_test(Fun) ->
    {timeout, 30, fun() -> try Fun() after shutdown() end end}.

fresh_store(Events) ->
    evoq_test_isolation:stop_leftover_evoq(),
    application:set_env(evoq, event_store_adapter, evoq_fake_boot_backend),
    application:set_env(evoq, subscription_adapter, evoq_fake_boot_backend),
    StoreId = list_to_atom("backfill_store_" ++ integer_to_list(erlang:unique_integer([positive]))),
    evoq_fake_boot_backend:seed(StoreId, Events),
    evoq_fake_boot_backend:reset(StoreId),
    ok = evoq_replay_probe:reset(),
    {ok, _} = application:ensure_all_started(telemetry),
    StoreId.

%% Start the routers, then the First group, settle, then the Then group.
boot(StoreId, First, Then) ->
    put(store_id, StoreId),
    lists:foreach(fun(M) -> started(M:start_link()) end,
                  [evoq_event_type_registry, evoq_type_provider,
                   evoq_event_router, evoq_pm_router, evoq_pm_instance_sup]),
    lists:foreach(fun start_now/1, First),
    settle(),
    lists:foreach(fun start_now/1, Then),
    settle().

start_late(Consumer) ->
    start_now(Consumer),
    settle().

start_now(subscription) -> started(evoq_store_subscription:start_link(get(store_id)));
start_now(order_pm) -> ok = evoq_process_manager:start(evoq_order_probe_pm, #{});
start_now(placed_handler) ->
    started(evoq_event_handler:start_link(evoq_order_placed_probe_handler, #{}));
start_now({named_b, Name}) ->
    started(evoq_event_handler:start_link(evoq_named_probe_b_handler, #{name => Name}));
start_now(ab_projection) ->
    started(evoq_projection:start_link(evoq_restart_probe_ab_projection, #{},
                                       #{store_id => get(store_id)})).

subscription_pid(StoreId) ->
    whereis(list_to_existing_atom("evoq_store_sub_" ++ atom_to_list(StoreId))).

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

settle() -> timer:sleep(300).

ns(Who) -> [N || {N, _} <- evoq_replay_probe:calls(Who)].

ab_projected() -> [TN || {TN, _} <- evoq_replay_probe:calls(ab_projection)].

%% What the order process manager handled: {Type, Order, types seen before}.
order_pm_seen() ->
    [{Type, Id, Seen} || {{Type, Id, #{seen := Seen}}, _} <- evoq_replay_probe:calls(order_pm)].

%% B1 .. BN, one type only.
bs(From, To) -> [event(?B, N, N) || N <- lists:seq(From, To)].

%% A1, B1, A2, B2, ... AN, BN.
interleaved(From, To) ->
    lists:append([[event(?A, N, 2 * N - 1), event(?B, N, 2 * N)] || N <- lists:seq(From, To)]).

event(Type, N, Pos) ->
    #evoq_event{event_id = <<Type/binary, "-", (integer_to_binary(N))/binary>>,
                event_type = Type, stream_id = <<"backfill-probe">>, version = Pos,
                data = #{n => N}, metadata = #{}, tags = undefined,
                timestamp = Pos, epoch_us = Pos}.

placed(Order, Pos) -> order_event(?PLACED, Order, Pos).
paid(Order, Pos) -> order_event(?PAID, Order, Pos).

order_event(Type, Order, Pos) ->
    #evoq_event{event_id = <<Type/binary, "-", Order/binary>>, event_type = Type,
                stream_id = <<"order-", Order/binary>>, version = Pos,
                data = #{order => Order}, metadata = #{}, tags = undefined,
                timestamp = Pos, epoch_us = Pos}.
