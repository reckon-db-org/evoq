%% @doc A restart must not re-fire what a node already reacted to.
%%
%% evoq_store_subscription rescans the whole store on every boot and used
%% to route every stored event to every handler and process manager as if
%% it were new. A process manager dispatched its whole command history
%% again and a side-effecting handler repeated every side effect: measured
%% live as 1174 re-publishes on one realm restart.
%%
%% The boundary is the persisted $all checkpoint: what this node had
%% consumed before it went down. Below it is REPLAY, delivered with
%% `replaying => true'; process managers only fold it into state, and a
%% handler declaring `replay_policy() -> skip' does not see it. At or
%% above it is NEW (appended while the node was down) and fires as it
%% always did.
%%
%% Each test is a real restart as far as evoq can tell: every evoq
%% process is stopped and started again between boots, and only the fake
%% store (evoq_fake_boot_backend) survives, as the real store would.
-module(evoq_store_subscription_replay_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-export([log/2, on_pm_command/4]).

-define(TYPE, <<"replay_probe_v1">>).

%%====================================================================
%% Tests
%%====================================================================

%% Handlers running before catch-up: the catch-up path.
a_restart_does_not_refire_side_effects_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(events(1, 5)),

        boot(StoreId, handlers_first),
        ?assertEqual([1, 2, 3, 4, 5], ns(skip_handler)),
        ?assertEqual(5, pm_dispatches()),
        shutdown(),

        boot(StoreId, handlers_first),
        %% Nothing new was appended, so nothing may fire again.
        ?assertEqual([1, 2, 3, 4, 5], ns(skip_handler)),
        ?assertEqual(5, pm_dispatches()),
        %% The process manager still rebuilt its state from the replay,
        %% through handle/3 as well as apply/2, and was told it was replay.
        ?assertEqual([1, 2, 3, 4, 5, 1, 2, 3, 4, 5], ns(pm_apply)),
        ?assertEqual([false, false, false, false, false, true, true, true, true, true],
                     replaying(pm_handle)),
        shutdown()
    end).

%% Handlers registering after catch-up ran: the backfill path, which is
%% how a multi-app umbrella (macula-realm) receives its history.
a_restart_does_not_refire_side_effects_via_backfill_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(events(1, 5)),

        boot(StoreId, subscription_first),
        ?assertEqual([1, 2, 3, 4, 5], ns(skip_handler)),
        ?assertEqual(5, pm_dispatches()),
        shutdown(),

        boot(StoreId, subscription_first),
        ?assertEqual([1, 2, 3, 4, 5], ns(skip_handler)),
        ?assertEqual(5, pm_dispatches()),
        shutdown()
    end).

%% What was appended while the node was down has never been delivered, so
%% it must fire, once, and only it.
events_appended_while_down_fire_exactly_once_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(events(1, 5)),
        boot(StoreId, handlers_first),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, events(1, 8)),
        boot(StoreId, handlers_first),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7, 8], ns(skip_handler)),
        ?assertEqual(8, pm_dispatches()),
        shutdown()
    end).

%% A handler that declares no policy keeps receiving replay, so an
%% in-memory read model built on evoq_event_handler still rebuilds. It is
%% told which events are replay, and new ones are not marked.
an_undeclared_handler_still_receives_replay_marked_as_such_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(events(1, 3)),
        boot(StoreId, handlers_first),
        ?assertEqual([false, false, false], replaying(open_handler)),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, events(1, 4)),
        boot(StoreId, handlers_first),
        ?assertEqual([1, 2, 3, 1, 2, 3, 4], ns(open_handler)),
        ?assertEqual([false, false, false, true, true, true, false],
                     replaying(open_handler)),
        shutdown()
    end).

%% ...and says so, once per boot, naming itself: a handler with side
%% effects that has not declared a policy is exactly the one to find.
an_undeclared_handler_receiving_replay_is_named_once_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(events(1, 3)),
        boot(StoreId, handlers_first),
        shutdown(),

        ok = logger:add_handler(?MODULE, ?MODULE,
                                #{level => warning, config => #{pid => self()}}),
        try
            boot(StoreId, handlers_first),
            Named = drain_replay_warnings([]),
            ?assertEqual([evoq_replay_probe_open_handler], Named)
        after
            _ = logger:remove_handler(?MODULE)
        end
    end).

%%====================================================================
%% Boot and shutdown, as a node restart looks to evoq
%%====================================================================

%% Stops whatever the test started even when an assertion fails, so one
%% red test cannot leave registered evoq processes behind for the next.
restart_test(Fun) ->
    {timeout, 30, fun() ->
        try Fun() after shutdown() end
    end}.

fresh_store(Events) ->
    application:set_env(evoq, event_store_adapter, evoq_fake_boot_backend),
    application:set_env(evoq, subscription_adapter, evoq_fake_boot_backend),
    StoreId = list_to_atom("replay_test_store_" ++
                           integer_to_list(erlang:unique_integer([positive]))),
    evoq_fake_boot_backend:seed(StoreId, Events),
    evoq_fake_boot_backend:reset(StoreId),
    ok = evoq_replay_probe:reset(),
    {ok, _} = application:ensure_all_started(telemetry),
    _ = telemetry:detach(?MODULE),
    ok = telemetry:attach(?MODULE, [evoq, process_manager, command],
                          fun ?MODULE:on_pm_command/4, #{}),
    StoreId.

boot(StoreId, handlers_first) ->
    start_infra(),
    start_consumers(),
    start_subscription(StoreId),
    settle();
boot(StoreId, subscription_first) ->
    start_infra(),
    start_subscription(StoreId),
    settle(),
    start_consumers(),
    settle().

start_infra() ->
    lists:foreach(fun(M) -> started(M:start_link()) end,
                  [evoq_event_type_registry, evoq_type_provider,
                   evoq_event_router, evoq_pm_router, evoq_pm_instance_sup]).

%% Every process a boot starts is remembered, so shutdown/0 stops exactly
%% those and never the eunit processes this one is also linked to.
started({ok, Pid}) ->
    put(started, [Pid | get_started()]),
    ok.

get_started() ->
    case get(started) of
        undefined -> [];
        Pids -> Pids
    end.

%% The process manager registers first. Backfill starts the moment a type
%% gets its first handler, so a consumer registering after that misses the
%% backfill entirely: a pre-existing limitation this module does not test.
start_consumers() ->
    ok = evoq_process_manager:start(evoq_replay_probe_pm, #{}),
    started(evoq_event_handler:start_link(evoq_replay_probe_skip_handler, #{})),
    started(evoq_event_handler:start_link(evoq_replay_probe_open_handler, #{})).

start_subscription(StoreId) ->
    started(evoq_store_subscription:start_link(StoreId)).

%% Everything the boot started, newest first, which puts the store
%% subscription (and with it terminate/2's ack flush) ahead of the handlers
%% and routers, as a clean node stop would.
shutdown() ->
    Pids = get_started(),
    erase(started),
    Subs = [P || P <- Pids, is_store_subscription(P)],
    lists:foreach(fun stop/1, Subs ++ (Pids -- Subs)).

is_store_subscription(Pid) ->
    case process_info(Pid, registered_name) of
        {registered_name, Name} ->
            lists:prefix("evoq_store_sub_", atom_to_list(Name));
        _ -> false
    end.

stop(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

settle() -> timer:sleep(300).

%%====================================================================
%% Observations
%%====================================================================

ns(Who) -> [N || {N, _} <- evoq_replay_probe:calls(Who)].

%% How many commands the process manager tried to dispatch, over all boots.
pm_dispatches() -> length(evoq_replay_probe:calls(pm_dispatch)).

on_pm_command(_Event, _Measurements, #{pm_module := evoq_replay_probe_pm}, _Config) ->
    evoq_replay_probe:record(pm_dispatch, 0, #{});
on_pm_command(_Event, _Measurements, _Metadata, _Config) ->
    ok.

replaying(Who) ->
    [maps:get(replaying, M, false) || {_, M} <- evoq_replay_probe:calls(Who)].

events(From, To) ->
    [#evoq_event{
        event_id = integer_to_binary(N),
        event_type = ?TYPE,
        stream_id = <<"replay-probe-stream">>,
        version = N,
        data = #{n => N},
        metadata = #{},
        tags = undefined,
        timestamp = N,
        epoch_us = N
     } || N <- lists:seq(From, To)].

%% logger handler: forwards evoq's replay warning, nothing else.
log(#{msg := {report, #{what := evoq_handler_received_replay_without_policy,
                        handler := Handler}}}, #{config := #{pid := Pid}}) ->
    Pid ! {replay_warning, Handler};
log(_Event, _Config) ->
    ok.

drain_replay_warnings(Acc) ->
    receive {replay_warning, H} -> drain_replay_warnings([H | Acc])
    after 300 -> lists:reverse(Acc)
    end.
