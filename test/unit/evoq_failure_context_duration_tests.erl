%%% @doc evoq_failure_context:get_duration/1 is elapsed time (evoq#12).
%%%
%%% It returned the difference of two wall-clock readings, so an NTP step
%%% back between the first failure and a retry handed a negative duration to
%%% a handler's on_error/4 backoff policy. The wall-clock fields stay (dead
%%% letter records show them); the duration is read from the monotonic clock.
-module(evoq_failure_context_duration_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% The wall clock stepped back a second between the first failure and the
%% retry; 40 ms really passed.
a_clock_step_back_gives_no_negative_duration_test() ->
    Ctx0 = evoq_failure_context:new(some_handler, #{}, boom),
    Ctx = stepped(Ctx0, -1000, 40),
    ?assertEqual(40, evoq_failure_context:get_duration(Ctx)).

%% A step forward does not inflate it either.
a_clock_step_forward_gives_the_elapsed_time_test() ->
    Ctx0 = evoq_failure_context:new(some_handler, #{}, boom),
    Ctx = stepped(Ctx0, 3600000, 40),
    ?assertEqual(40, evoq_failure_context:get_duration(Ctx)).

%% Through the API, with no clock games: a retry reads a duration that is
%% never negative and at least the time slept between failures.
increment_measures_elapsed_time_test() ->
    Ctx0 = evoq_failure_context:new(some_handler, #{}, boom),
    timer:sleep(20),
    Ctx = evoq_failure_context:increment(Ctx0),
    ?assert(evoq_failure_context:get_duration(Ctx) >= 20).

%% The contexts a backoff policy really sees are built by the event handler
%% and the projection. Each probe fails, is retried after 30 ms, fails again;
%% the second on_error/4 reads at least that delay, and the first reads no
%% time at all, since only one failure has happened.
an_event_handler_hands_on_error_the_elapsed_time_test_() ->
    {timeout, 30, fun() ->
        ensure_registry(),
        {ok, Pid} = evoq_event_handler:start_link(
                      evoq_duration_probe_handler, #{sink => self()},
                      #{identity => evoq_duration_probe_handler}),
        try
            ok = evoq_event_handler:notify(Pid, <<"duration_probe_v1">>, #{}, #{version => 0}),
            assert_failures_read()
        after
            stop(Pid)
        end
    end}.

a_projection_hands_on_error_the_elapsed_time_test_() ->
    {timeout, 30, fun() ->
        ensure_registry(),
        {ok, Pid} = evoq_projection:start_link(
                      evoq_duration_probe_projection, #{sink => self()}),
        try
            ok = evoq_projection:notify(Pid, <<"duration_probe_v1">>, #{}, #{version => 0}),
            assert_failures_read()
        after
            stop(Pid)
        end
    end}.

assert_failures_read() ->
    ?assertEqual(0, failure_read(1)),
    ?assert(failure_read(2) >= evoq_duration_probe_script:retry_delay()).

failure_read(Attempt) ->
    receive {failure_read, Attempt, Duration} -> Duration
    after 5000 -> error({on_error_never_read_attempt, Attempt})
    end.

ensure_registry() ->
    {ok, _} = application:ensure_all_started(telemetry),
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link(), ok;
        _ -> ok
    end.

stop(Pid) ->
    unlink(Pid),
    catch gen_server:stop(Pid),
    ok.

%% The context as a retry would leave it: the wall clock moved WallDelta ms,
%% the monotonic clock MonoDelta ms.
stepped(#evoq_failure_context{first_failure_at = First} = Ctx, WallDelta, MonoDelta) ->
    Moved = Ctx#evoq_failure_context{last_failure_at = First + WallDelta},
    mono_moved(Moved, MonoDelta).

mono_moved(Ctx, MonoDelta) ->
    Ctx#evoq_failure_context{
      last_failure_mono = Ctx#evoq_failure_context.first_failure_mono + MonoDelta}.
