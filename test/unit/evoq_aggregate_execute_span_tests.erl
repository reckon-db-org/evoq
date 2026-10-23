%%% @doc Every [evoq, aggregate, execute, start] is matched by exactly one
%%% stop or exception (evoq#11).
%%%
%%% A failed append (a version conflict, an integrity violation, any other
%%% store error) answered the caller and emitted nothing, so the span stayed
%%% open. A version conflict is the normal retry path: the dispatcher retries
%%% and the aggregate emits a fresh start each time, so an in-flight gauge
%%% (+1 on start, -1 on stop or exception) drifted up by one per conflict.
%%%
%%% `evoq_event_store' is mocked, as in evoq_aggregate_noop_tests: the
%%% defect is in the aggregate's reply path, so the store only has to answer.
-module(evoq_aggregate_execute_span_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_telemetry.hrl").

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{}}.

execute(_State, #{command_type := <<"note">>}) ->
    {ok, [#{event_type => <<"noted_v1">>}]};
execute(_State, #{command_type := <<"raise">>}) ->
    error(execute_raised);
execute(_State, #{command_type := <<"junk">>}) ->
    not_an_answer;
execute(_State, #{command_type := <<"bad_apply">>}) ->
    {ok, [#{event_type => <<"unapplicable_v1">>}]}.

apply(_State, #{event_type := <<"unapplicable_v1">>}) ->
    error(apply_raised);
apply(State, _Event) ->
    State.

%%====================================================================
%% Tests
%%====================================================================

a_version_conflict_closes_the_span_with_an_exception_test() ->
    assert_closed_by_exception({error, {wrong_expected_version, 0, 3}}).

an_integrity_violation_closes_the_span_with_an_exception_test() ->
    assert_closed_by_exception({error, {integrity_violation, #{layer => storage}}}).

any_other_append_error_closes_the_span_with_an_exception_test() ->
    assert_closed_by_exception({error, timeout}).

%% The accepted command still closes with a stop and no exception, so the
%% three cases above cannot pass on an aggregate that emits an exception for
%% everything.
an_append_that_succeeds_closes_the_span_with_a_stop_test() ->
    with_store(fun(_Store, _Stream, Version, _Events) -> {ok, Version + 1} end,
               fun() ->
                   Id = aggregate_id(),
                   {ok, Pid} = evoq_aggregate:start_link(?MODULE, Id, test_store),
                   {ok, _, _} = evoq_aggregate:execute_command(Pid, command(Id)),
                   ?assertEqual(#{start => 1, stop => 1, exception => 0}, spans())
               end).

%% A command that crashes the aggregate still closes its span: a raising
%% execute/2, an answer execute/2 is not allowed to give, a raising apply/2
%% and a raising append each emit one exception, and the crash itself is
%% unchanged (the aggregate dies, the caller gets the error).
a_raising_execute_closes_the_span_with_an_exception_test() ->
    assert_crash_closed_by_exception(<<"raise">>, fun accept/4, execute_raised).

an_unexpected_execute_answer_closes_the_span_with_an_exception_test() ->
    assert_crash_closed_by_exception(<<"junk">>, fun accept/4, {case_clause, not_an_answer}).

a_raising_apply_closes_the_span_with_an_exception_test() ->
    assert_crash_closed_by_exception(<<"bad_apply">>, fun accept/4, apply_raised).

a_raising_append_closes_the_span_with_an_exception_test() ->
    assert_crash_closed_by_exception(<<"note">>,
                                     fun(_Store, _Stream, _Version, _Events) ->
                                         error(append_raised)
                                     end,
                                     append_raised).

%%====================================================================
%% Helpers
%%====================================================================

assert_closed_by_exception({error, Reason} = AppendError) ->
    with_store(fun(_Store, _Stream, _Version, _Events) -> AppendError end,
               fun() ->
                   Id = aggregate_id(),
                   {ok, Pid} = evoq_aggregate:start_link(?MODULE, Id, test_store),
                   _ = evoq_aggregate:execute_command(Pid, command(Id)),
                   ?assertEqual(#{start => 1, stop => 0, exception => 1}, spans()),
                   ?assertEqual([Reason], exception_reasons())
               end).

assert_crash_closed_by_exception(CommandType, Append, Reason) ->
    with_store(Append,
               fun() ->
                   Id = aggregate_id(),
                   {ok, Pid} = evoq_aggregate:start_link(?MODULE, Id, test_store),
                   unlink(Pid),
                   Command = evoq_command:new(note, ?MODULE, Id, #{command_type => CommandType}),
                   ?assertMatch({error, _}, evoq_aggregate:execute_command(Pid, Command)),
                   ?assertNot(is_process_alive(Pid)),
                   ?assertEqual(#{start => 1, stop => 0, exception => 1}, spans()),
                   ?assertEqual([Reason], exception_reasons())
               end).

accept(_Store, _Stream, Version, _Events) ->
    {ok, Version + 1}.

aggregate_id() ->
    <<"span-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

command(Id) ->
    evoq_command:new(note, ?MODULE, Id, #{command_type => <<"note">>}).

%% Telemetry handlers run in the emitting process (the aggregate), so each
%% event is sent to the test process and counted here.
spans() ->
    Received = drain([]),
    #{start => count(start, Received), stop => count(stop, Received),
      exception => count(exception, Received)}.

exception_reasons() ->
    get(exception_reasons).

drain(Acc) ->
    receive
        {span, exception, Meta} ->
            put(exception_reasons, [maps:get(error, Meta) | get_list(exception_reasons)]),
            drain([exception | Acc]);
        {span, Kind, _Meta} ->
            drain([Kind | Acc])
    after 100 ->
        Acc
    end.

get_list(Key) ->
    list_or_empty(get(Key)).

list_or_empty(undefined) -> [];
list_or_empty(List) -> List.

count(Kind, Received) ->
    length([K || K <- Received, K =:= Kind]).

with_store(Append, Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    erase(exception_reasons),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4, Append),
    {ok, Started} = application:ensure_all_started(evoq),
    Self = self(),
    HandlerId = {?MODULE, Self},
    ok = telemetry:attach_many(
           HandlerId,
           [?TELEMETRY_AGGREGATE_EXECUTE_START, ?TELEMETRY_AGGREGATE_EXECUTE_STOP,
            ?TELEMETRY_AGGREGATE_EXECUTE_EXCEPTION],
           fun(Event, _Measurements, Meta, _Config) ->
               Self ! {span, lists:last(Event), Meta}
           end, undefined),
    try
        Body()
    after
        telemetry:detach(HandlerId),
        lists:foreach(fun application:stop/1, lists:reverse(Started)),
        meck:unload(evoq_event_store)
    end.
