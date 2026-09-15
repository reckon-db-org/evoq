%% @doc Slice 2, condition 1: the checkpointed ordered consumer with a
%% single source during catch-up on the {epoch_us, stream_id, version}
%% key.
%%
%% The store, read in global order from a durable checkpoint, is the only
%% source of processed events; a deliver/4 cast is only a wakeup and its
%% payload is never processed directly. So the checkpoint can never pass an
%% event the handler has not processed, and a restart resumes exactly where
%% it left off.
%%
%% Each test is verified red-first by disabling the specific mechanism it
%% guards (see the report): with catch-up, persistence, or the wakeup
%% neutralised, the matching assertion fails.
-module(evoq_checkpointed_consumer_tests).

-include_lib("eunit/include/eunit.hrl").

consumer_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [
      {"catch-up processes seeded history in global order, once each",
       fun catch_up_processes_in_order/0},
      {"resume after a crash reads strictly after the checkpoint",
       fun resume_reads_strictly_after_checkpoint/0},
      {"a live wakeup delivers newly appended events, in order, none skipped",
       fun live_wakeup_delivers_new_in_order/0},
      {"a wakeup carrying a forged event changes nothing",
       fun wakeup_ignores_forged_event/0},
      {"the {epoch_us, stream_id, version} key's order survives a round trip",
       fun checkpoint_key_order_survives_round_trip/0}
     ]}.

setup() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(evoq),
    evoq_event_store:set_adapter(evoq_fake_store),
    evoq_fake_store:reset(),
    ok.

cleanup(_) ->
    application:stop(evoq),
    ok.

%%====================================================================
%% Tests
%%====================================================================

catch_up_processes_in_order() ->
    evoq_fake_store:seed(seq_events([<<"e1">>, <<"e2">>, <<"e3">>, <<"e4">>, <<"e5">>])),

    {ok, C} = start_consumer(),
    %% A live wakeup for an event several positions ahead must not let the
    %% checkpoint jump past e1..e4; the store is re-read in order.
    evoq_event_handler:deliver(C, <<"seq_evt_v1">>, #{event_id => <<"e5">>}, #{}),

    ?assertEqual([<<"e1">>, <<"e2">>, <<"e3">>, <<"e4">>, <<"e5">>],
                 collect(5, 2000)),
    ?assertEqual(timeout, next(300)),

    stop_consumer(C).

%% Crash after the first two events, restart, and assert the resumed
%% consumer runs strictly after the durable checkpoint: the newly appended
%% third and fourth run once, the first two never run again. The crash is a
%% hard kill (terminate/2 is skipped), so this also proves the checkpoint
%% was durable BEFORE the next event was taken -- persist-before-advance.
resume_reads_strictly_after_checkpoint() ->
    evoq_fake_store:seed(seq_events([<<"e1">>, <<"e2">>])),

    {ok, C1} = start_consumer(),
    ?assertEqual([<<"e1">>, <<"e2">>], collect(2, 2000)),
    crash_consumer(C1),

    %% One append of several events, after the crash.
    evoq_fake_store:append(seq_events_from(3, [<<"e3">>, <<"e4">>])),

    {ok, C2} = start_consumer(),
    ?assertEqual([<<"e3">>, <<"e4">>], collect(2, 2000)),
    ?assertEqual(timeout, next(300)),

    stop_consumer(C2).

%% The wakeup-only design, proven directly: a cast carrying a forged event
%% with a later key that is NOT in the store changes nothing. The handler
%% acts only on stored events read after its checkpoint.
wakeup_ignores_forged_event() ->
    evoq_fake_store:seed(seq_events([<<"e1">>, <<"e2">>])),

    {ok, C} = start_consumer(),
    ?assertEqual([<<"e1">>, <<"e2">>], collect(2, 2000)),

    Forged = #{event_id => <<"forged">>, event_type => <<"seq_evt_v1">>,
               epoch_us => 9999, stream_id => <<"s">>, version => 99},
    evoq_event_handler:deliver(C, <<"seq_evt_v1">>, Forged,
                               #{version => 99, stream_id => <<"s">>, epoch_us => 9999}),
    ?assertEqual(timeout, next(500)),

    %% Control: a real append IS delivered on the next wakeup, so the
    %% handler is live, not merely inert.
    evoq_fake_store:append(seq_events_from(3, [<<"e3">>])),
    evoq_event_handler:deliver(C, <<"seq_evt_v1">>, #{event_id => <<"e3">>}, #{}),
    ?assertEqual(<<"e3">>, next(2000)),

    stop_consumer(C).

%% Two keys that tie on epoch_us but differ in stream_id and version must
%% still compare the same way after being stored and reloaded -- the
%% checkpoint store must not mangle the tuple.
checkpoint_key_order_survives_round_trip() ->
    KeyA = {100, <<"stream-a">>, 1},
    KeyB = {100, <<"stream-b">>, 2},
    ?assert(KeyA < KeyB),

    ok = evoq_checkpoint_store_ets:save(rt_a, {5, KeyA}),
    ok = evoq_checkpoint_store_ets:save(rt_b, {5, KeyB}),
    {ok, {5, ReloadedA}} = evoq_checkpoint_store_ets:load(rt_a),
    {ok, {5, ReloadedB}} = evoq_checkpoint_store_ets:load(rt_b),

    ?assertEqual(KeyA, ReloadedA),
    ?assertEqual(KeyB, ReloadedB),
    ?assert(ReloadedA < ReloadedB).

live_wakeup_delivers_new_in_order() ->
    evoq_fake_store:seed(seq_events([<<"e1">>, <<"e2">>])),

    {ok, C} = start_consumer(),
    ?assertEqual([<<"e1">>, <<"e2">>], collect(2, 2000)),

    evoq_fake_store:append(seq_events_from(3, [<<"e3">>, <<"e4">>])),
    %% A wakeup: the handler re-reads the store from its checkpoint.
    evoq_event_handler:deliver(C, <<"seq_evt_v1">>, #{event_id => <<"e3">>}, #{}),

    ?assertEqual([<<"e3">>, <<"e4">>], collect(2, 2000)),

    stop_consumer(C).

%%====================================================================
%% Helpers
%%====================================================================

start_consumer() ->
    Opts = #{store_id => fake_store, checkpoint_store => evoq_checkpoint_store_ets},
    evoq_event_handler:start_link(evoq_ordered_consumer, #{report_to => self()}, Opts).

stop_consumer(Pid) ->
    down_after(Pid, shutdown).

%% A hard kill: terminate/2 does not run, modelling a real crash.
crash_consumer(Pid) ->
    down_after(Pid, kill).

down_after(Pid, Reason) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, Reason),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

seq_events(Ids) ->
    seq_events_from(1, Ids).

seq_events_from(Start, Ids) ->
    {Events, _} = lists:mapfoldl(
        fun(Id, Pos) -> {evoq_fake_store:event(<<"seq_evt_v1">>, Id, Pos), Pos + 1} end,
        Start, Ids),
    Events.

collect(N, Timeout) ->
    collect(N, Timeout, []).

collect(0, _Timeout, Acc) ->
    lists:reverse(Acc);
collect(N, Timeout, Acc) ->
    receive {consumed, Id} -> collect(N - 1, Timeout, [Id | Acc])
    after Timeout -> lists:reverse(Acc)
    end.

next(Timeout) ->
    receive {consumed, Id} -> Id
    after Timeout -> timeout
    end.
