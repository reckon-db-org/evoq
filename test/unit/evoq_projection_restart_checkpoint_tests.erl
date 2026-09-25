%% @doc A projection's saved checkpoint must name the same event in every boot
%% (evoq #1).
%%
%% A projection skips an event at or below its checkpoint as "already
%% projected", and with a checkpoint store that checkpoint survives a restart.
%% It is only safe if the number it compares means the same event after the
%% restart as before. These tests restart for real (every evoq process stops
%% and starts again; only the fake store and the checkpoint store survive, as
%% real ones would) and change what the store subscription numbers between
%% boots, then assert every event of the projection's type is projected
%% exactly once across both boots.
-module(evoq_projection_restart_checkpoint_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-define(A, <<"restart_a_v1">>).
-define(B, <<"restart_b_v1">>).

%% A handler for an unrelated type is removed between boots. The store
%% subscription's per-boot counter only counts events that have a handler, so
%% the same A events get lower numbers in boot 2, and events appended while
%% the node was down land at or below the old checkpoint.
removing_an_unrelated_handler_skips_no_event_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),

        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4, 5], projected()),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 7)),
        boot(StoreId, [projection]),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7], projected()),
        shutdown()
    end).

%% The reverse: a handler for an unrelated type is added between boots, which
%% numbers the same A events higher, so already-projected ones rise above the
%% old checkpoint and are projected again.
adding_an_unrelated_handler_repeats_no_event_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),

        boot(StoreId, [projection]),
        ?assertEqual([1, 2, 3, 4, 5], projected()),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 6)),
        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4, 5, 6], projected()),
        shutdown()
    end).

%% A restart with nothing new must project nothing again.
a_quiet_restart_projects_nothing_again_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 4)),
        boot(StoreId, [projection, b_handler]),
        shutdown(),
        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4], projected()),
        shutdown()
    end).

%% Events projected live (pushed after catch-up) carry their global position
%% too, so a checkpoint saved from the live feed survives the same change of
%% handlers. Boot 1 has no B handler, so its per-boot counter differs from
%% the global position; with both present they coincide and prove nothing.
a_live_checkpoint_survives_adding_an_unrelated_handler_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),

        boot(StoreId, [projection]),
        evoq_fake_boot_backend:push_live(StoreId, interleaved(6, 6)),
        timer:sleep(200),
        ?assertEqual([1, 2, 3, 4, 5, 6], projected()),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 8)),
        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7, 8], projected()),
        shutdown()
    end).

%% A rebuild replays every event of the projection's types once and leaves
%% the checkpoint at the last one's global position, the same number the
%% store subscription gives it, so a restart after a rebuild skips and
%% repeats nothing either.
a_rebuild_checkpoints_on_the_global_position_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),
        boot(StoreId, [projection, b_handler]),
        ok = evoq_replay_probe:reset(),

        ok = evoq_projection:rebuild(projection_pid()),
        ?assertEqual([1, 2, 3, 4, 5], projected()),
        ?assertEqual(8, evoq_projection:get_checkpoint(projection_pid())),
        ?assertEqual({ok, 8}, evoq_restart_probe_checkpoint_store:load(
                                evoq_restart_probe_projection)),
        shutdown(),

        ok = evoq_replay_probe:reset(),
        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 6)),
        boot(StoreId, [projection]),
        ?assertEqual([6], projected()),
        shutdown()
    end).

%% A rebuild pages through the store instead of reading one batch (evoq #6,
%% the rebuild half): a store larger than a batch rebuilds in full.
a_rebuild_is_not_capped_at_one_batch_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store([event(?A, N, N) || N <- lists:seq(1, 2500)]),
        boot(StoreId, [projection]),
        ok = evoq_replay_probe:reset(),

        ok = evoq_projection:rebuild(projection_pid()),
        ?assertEqual(lists:seq(1, 2500), projected()),
        ?assertEqual(2499, evoq_projection:get_checkpoint(projection_pid())),
        shutdown()
    end).

%% A projection on more than one type that registers after the store
%% subscription's catch-up (every projection in an application that boots
%% after the one that owns the store) gets its history through backfill.
%% Backfilling one type at a time moved the checkpoint to the first type's
%% last global position, and the second type's backfill then skipped its
%% own older events as already projected: [A1,A2,A3,B3]. One backfill pass
%% over all the types a projection registers, in global order, delivers
%% every event once, in store order.
%%
%% Both types are new here (no other handler has them): backfill runs only
%% for a type's first handler ever, so a type another handler already
%% covers is not backfilled at all, a separate gap left for 2.0.0.
a_late_multi_type_projection_gets_every_event_in_store_order_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 3)),
        boot(StoreId, []),
        start_late_ab_projection(),

        ?assertEqual([{?A, 1}, {?B, 1}, {?A, 2}, {?B, 2}, {?A, 3}, {?B, 3}],
                     ab_projected()),
        shutdown()
    end).

%% The same late multi-type projection with a checkpoint store, over a
%% restart with events appended while the node was down: every event of
%% both types projected exactly once across the two boots.
a_late_multi_type_projection_resumes_across_a_restart_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 3)),
        boot(StoreId, []),
        start_late_ab_projection(),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 5)),
        boot(StoreId, []),
        start_late_ab_projection(),
        ?assertEqual(lists:append([[{?A, N}, {?B, N}] || N <- lists:seq(1, 5)]),
                     ab_projected()),
        shutdown()
    end).

%% reckon-db arms its trigger before its own catch-up and documents that an
%% event written in between may be delivered twice. A duplicate counted as a
%% new position shifted every later live position up by one, so after a
%% restart the checkpoint sat on an event appended while the node was down,
%% which was then skipped (and the duplicate projected twice).
a_live_duplicate_delivery_shifts_no_position_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),
        boot(StoreId, [projection, b_handler]),
        evoq_fake_boot_backend:push_live(StoreId, interleaved(6, 6)),
        redeliver(StoreId, interleaved(6, 6)),
        timer:sleep(200),
        ?assertEqual([1, 2, 3, 4, 5, 6], projected()),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 8)),
        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7, 8], projected()),
        shutdown()
    end).

%% A reconnect whose pre-subscribe ack failed resumes reckon-db's catch-up
%% from the older checkpoint and redelivers events this boot's own catch-up
%% already scanned. Those are recognised as well, not counted as new.
a_redelivery_of_caught_up_events_shifts_no_position_test_() ->
    restart_test(fun() ->
        StoreId = fresh_store(interleaved(1, 5)),
        boot(StoreId, [projection, b_handler]),
        redeliver(StoreId, interleaved(4, 5)),
        timer:sleep(200),
        ?assertEqual([1, 2, 3, 4, 5], projected()),
        shutdown(),

        evoq_fake_boot_backend:seed(StoreId, interleaved(1, 7)),
        boot(StoreId, [projection, b_handler]),
        ?assertEqual([1, 2, 3, 4, 5, 6, 7], projected()),
        shutdown()
    end).

%%====================================================================
%% Boot and shutdown
%%====================================================================

restart_test(Fun) ->
    {timeout, 30, fun() ->
        try Fun() after shutdown() end
    end}.

fresh_store(Events) ->
    evoq_test_isolation:stop_leftover_evoq(),
    application:set_env(evoq, event_store_adapter, evoq_fake_boot_backend),
    application:set_env(evoq, subscription_adapter, evoq_fake_boot_backend),
    StoreId = list_to_atom("restart_ckpt_store_" ++
                           integer_to_list(erlang:unique_integer([positive]))),
    evoq_fake_boot_backend:seed(StoreId, Events),
    evoq_fake_boot_backend:reset(StoreId),
    ok = evoq_replay_probe:reset(),
    ok = evoq_restart_probe_checkpoint_store:reset(),
    {ok, _} = application:ensure_all_started(telemetry),
    StoreId.

%% Consumers first, then the subscription: the catch-up path.
boot(StoreId, Consumers) ->
    put(store_id, StoreId),
    lists:foreach(fun(M) -> started(M:start_link()) end,
                  [evoq_event_type_registry, evoq_type_provider,
                   evoq_event_router, evoq_pm_router, evoq_pm_instance_sup]),
    lists:foreach(fun start_consumer/1, Consumers),
    started(evoq_store_subscription:start_link(StoreId)),
    timer:sleep(300).

start_consumer(projection) ->
    {ok, Pid} = Started = evoq_projection:start_link(
                            evoq_restart_probe_projection, #{},
                            #{checkpoint_store => evoq_restart_probe_checkpoint_store,
                              store_id => get(store_id)}),
    put(projection_pid, Pid),
    started(Started);
start_consumer(b_handler) ->
    started(evoq_event_handler:start_link(evoq_restart_probe_b_handler, #{})).

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

%%====================================================================
%% Observations and fixtures
%%====================================================================

projection_pid() -> get(projection_pid).

%% The multi-type projection, started after the store subscription's
%% catch-up, with the persistent checkpoint store.
start_late_ab_projection() ->
    started(evoq_projection:start_link(
              evoq_restart_probe_ab_projection, #{},
              #{checkpoint_store => evoq_restart_probe_checkpoint_store,
                store_id => get(store_id)})),
    timer:sleep(300).

ab_projected() -> [TN || {TN, _} <- evoq_replay_probe:calls(ab_projection)].

%% The second copy of a delivery, as reckon-db's trigger/catch-up overlap
%% sends it: the same events again on the live path, not appended again.
redeliver(StoreId, Events) ->
    list_to_existing_atom("evoq_store_sub_" ++ atom_to_list(StoreId)) ! {events, Events},
    ok.

%% Every A event projected, over all boots, in delivery order.
projected() -> [N || {N, _} <- evoq_replay_probe:calls(projection)].

%% A1, B1, A2, B2, ... AN, BN: one type-B event after each type-A event.
interleaved(From, To) ->
    lists:append([[event(?A, N, 2 * N - 1), event(?B, N, 2 * N)] || N <- lists:seq(From, To)]).

event(Type, N, Pos) ->
    #evoq_event{
        event_id = <<Type/binary, "-", (integer_to_binary(N))/binary>>,
        event_type = Type,
        stream_id = <<"restart-probe-", Type/binary>>,
        version = N,
        data = #{n => N},
        metadata = #{},
        tags = undefined,
        timestamp = Pos,
        epoch_us = Pos
    }.
