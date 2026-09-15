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
      {"a resume restart reads from the checkpoint, not from the start",
       fun resume_reads_from_checkpoint/0},
      {"a live wakeup delivers newly appended events, in order, none skipped",
       fun live_wakeup_delivers_new_in_order/0}
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

resume_reads_from_checkpoint() ->
    evoq_fake_store:seed(seq_events([<<"e1">>, <<"e2">>, <<"e3">>])),

    {ok, C1} = start_consumer(),
    ?assertEqual([<<"e1">>, <<"e2">>, <<"e3">>], collect(3, 2000)),
    stop_consumer(C1),

    %% One append of several events, then a restart. The resumed consumer
    %% starts at its checkpoint: it sees only the new events, in order, and
    %% does not reprocess history.
    evoq_fake_store:append(seq_events_from(4, [<<"e4">>, <<"e5">>])),

    {ok, C2} = start_consumer(),
    ?assertEqual([<<"e4">>, <<"e5">>], collect(2, 2000)),
    ?assertEqual(timeout, next(300)),

    stop_consumer(C2).

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
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
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
