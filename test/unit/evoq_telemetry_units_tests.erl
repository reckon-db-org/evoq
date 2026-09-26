%% @doc Telemetry durations are elapsed time, in native units (evoq #7).
%%
%% Durations were the difference of two erlang:system_time(microsecond)
%% readings: the wall clock, which an NTP step or a time warp moves, so a
%% duration could be wrong or negative; and microseconds, where telemetry's
%% convention (and every consumer that follows it with
%% erlang:convert_time_unit(D, native, _)) expects native units, a 1000x
%% misreading on Linux. A duration comes from the monotonic clock in native
%% units now, and a start event's system_time is native wall-clock time.
-module(evoq_telemetry_units_tests).

-include_lib("eunit/include/eunit.hrl").

-define(SLEEP_MS, 50).

%% The helpers every site uses.
the_duration_helper_measures_native_monotonic_time_test() ->
    Start = evoq_telemetry:monotonic_start(),
    timer:sleep(?SLEEP_MS),
    assert_about_sleep(evoq_telemetry:duration_since(Start)).

span_reports_a_native_duration_and_a_native_start_time_test() ->
    Events = capture([[evoq, test_span, start], [evoq, test_span, stop]], fun() ->
        evoq_telemetry:span([evoq, test_span], #{}, fun() -> timer:sleep(?SLEEP_MS) end)
    end),
    #{system_time := SystemTime} = measurements([evoq, test_span, start], Events),
    ?assert(abs(erlang:system_time() - SystemTime) <
            erlang:convert_time_unit(5, second, native)),
    #{duration := D} = measurements([evoq, test_span, stop], Events),
    assert_about_sleep(D).

an_event_handler_reports_a_native_duration_test_() ->
    {setup, fun start_registry/0, fun stop_all/1,
     fun(_) -> ?_test(begin
         {ok, Pid} = evoq_event_handler:start_link(evoq_slow_probe_handler, #{}),
         Events = capture([[evoq, handler, event, stop]], fun() ->
             ok = evoq_event_handler:notify(Pid, <<"slow_probe_v1">>, #{}, #{version => 0}),
             timer:sleep(?SLEEP_MS * 4)
         end),
         unlink(Pid), exit(Pid, shutdown),
         #{duration := D} = measurements([evoq, handler, event, stop], Events),
         assert_about_sleep(D)
     end) end}.

a_projection_reports_a_native_duration_test_() ->
    {setup, fun start_registry/0, fun stop_all/1,
     fun(_) -> ?_test(begin
         {ok, Pid} = evoq_projection:start_link(evoq_slow_probe_projection, #{}),
         Events = capture([[evoq, projection, stop]], fun() ->
             evoq_projection:notify(Pid, <<"slow_probe_v1">>, #{}, #{version => 0}),
             timer:sleep(?SLEEP_MS * 4)
         end),
         unlink(Pid), exit(Pid, shutdown),
         #{duration := D} = measurements([evoq, projection, stop], Events),
         assert_about_sleep(D)
     end) end}.

%% Guard: no module measures a duration by subtracting wall-clock readings.
%% The sites that are not exercised above (aggregate execute, command
%% dispatch) go through the same helpers; this keeps any of them from
%% drifting back.
no_duration_is_taken_from_the_wall_clock_test() ->
    {ok, Files} = file:list_dir(src_dir()),
    Offenders = [F || F <- Files, filename:extension(F) =:= ".erl",
                      {ok, Bin} <- [file:read_file(filename:join(src_dir(), F))],
                      re:run(Bin, "system_time\\(microsecond\\)\\s*-", []) =/= nomatch],
    ?assertEqual([], Offenders).

%%====================================================================

assert_about_sleep(D) ->
    Ms = erlang:convert_time_unit(D, native, millisecond),
    ?assert(Ms >= ?SLEEP_MS - 5),
    ?assert(Ms < ?SLEEP_MS * 20).

start_registry() ->
    {ok, _} = application:ensure_all_started(telemetry),
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, R} = evoq_event_type_registry:start_link(),
    [R].

stop_all(Pids) ->
    [begin unlink(P), exit(P, shutdown) end || P <- Pids],
    ok.

capture(EventNames, Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Id = {?MODULE, make_ref()},
    ok = telemetry:attach_many(Id, EventNames,
                               fun(Name, M, _Meta, _) -> Self ! {telemetry, Name, M} end, #{}),
    try Fun() after telemetry:detach(Id) end,
    collect([]).

collect(Acc) ->
    receive {telemetry, Name, M} -> collect([{Name, M} | Acc])
    after 0 -> lists:reverse(Acc)
    end.

measurements(Name, Events) ->
    {Name, M} = lists:keyfind(Name, 1, Events),
    M.

src_dir() ->
    filename:join(code:lib_dir(evoq), "src").
