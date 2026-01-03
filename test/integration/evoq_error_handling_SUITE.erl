%% @doc Integration tests for error handling.
%%
%% Tests:
%% - Error handler behavior
%% - Failure context tracking
%% - Retry strategies
%% - Dead letter store
%% - Consistency acknowledgments
%%
%% @author Reckon-DB
-module(evoq_error_handling_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    failure_context_new_test/1,
    failure_context_increment_test/1,
    failure_context_duration_test/1,
    retry_strategy_immediate_test/1,
    retry_strategy_fixed_test/1,
    retry_strategy_exponential_test/1,
    retry_strategy_exponential_jitter_test/1,
    dead_letter_store_test/1,
    dead_letter_list_test/1,
    dead_letter_retry_test/1,
    error_handler_default_action_test/1,
    consistency_wait_empty_test/1,
    consistency_acknowledge_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, failure_context_tests},
        {group, retry_strategy_tests},
        {group, dead_letter_tests},
        {group, error_handler_tests},
        {group, consistency_tests}
    ].

groups() ->
    [
        {failure_context_tests, [sequence], [
            failure_context_new_test,
            failure_context_increment_test,
            failure_context_duration_test
        ]},
        {retry_strategy_tests, [sequence], [
            retry_strategy_immediate_test,
            retry_strategy_fixed_test,
            retry_strategy_exponential_test,
            retry_strategy_exponential_jitter_test
        ]},
        {dead_letter_tests, [sequence], [
            dead_letter_store_test,
            dead_letter_list_test,
            dead_letter_retry_test
        ]},
        {error_handler_tests, [sequence], [
            error_handler_default_action_test
        ]},
        {consistency_tests, [sequence], [
            consistency_wait_empty_test,
            consistency_acknowledge_test
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    application:ensure_all_started(evoq),
    Config.

end_per_suite(_Config) ->
    application:stop(evoq),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Failure Context Tests
%%====================================================================

failure_context_new_test(_Config) ->
    Event = #{event_type => <<"test">>, data => #{}},
    Error = {error, test_error},
    Handler = test_handler,

    Context = evoq_failure_context:new(Handler, Event, Error),

    ?assertEqual(1, evoq_failure_context:get_attempt(Context)),
    ?assertEqual(Error, evoq_failure_context:get_error(Context)),
    ?assertEqual(Event, evoq_failure_context:get_event(Context)),
    ?assertEqual(Handler, evoq_failure_context:get_handler(Context)),
    ok.

failure_context_increment_test(_Config) ->
    Event = #{event_type => <<"test">>, data => #{}},
    Context1 = evoq_failure_context:new(test_handler, Event, {error, test}),

    ?assertEqual(1, evoq_failure_context:get_attempt(Context1)),

    Context2 = evoq_failure_context:increment(Context1),
    ?assertEqual(2, evoq_failure_context:get_attempt(Context2)),

    Context3 = evoq_failure_context:increment(Context2),
    ?assertEqual(3, evoq_failure_context:get_attempt(Context3)),
    ok.

failure_context_duration_test(_Config) ->
    Event = #{event_type => <<"test">>, data => #{}},
    Context1 = evoq_failure_context:new(test_handler, Event, {error, test}),

    %% Small delay
    timer:sleep(10),

    Context2 = evoq_failure_context:increment(Context1),
    Duration = evoq_failure_context:get_duration(Context2),

    ?assert(Duration >= 10),
    ?assert(Duration < 1000),
    ok.

%%====================================================================
%% Retry Strategy Tests
%%====================================================================

retry_strategy_immediate_test(_Config) ->
    Strategy = evoq_retry_strategy:immediate(),

    ?assertEqual(0, evoq_retry_strategy:next_delay(Strategy, 1)),
    ?assertEqual(0, evoq_retry_strategy:next_delay(Strategy, 5)),
    ?assertEqual(0, evoq_retry_strategy:next_delay(Strategy, 100)),
    ok.

retry_strategy_fixed_test(_Config) ->
    Strategy = evoq_retry_strategy:fixed(1000),

    ?assertEqual(1000, evoq_retry_strategy:next_delay(Strategy, 1)),
    ?assertEqual(1000, evoq_retry_strategy:next_delay(Strategy, 5)),
    ?assertEqual(1000, evoq_retry_strategy:next_delay(Strategy, 100)),
    ok.

retry_strategy_exponential_test(_Config) ->
    Strategy = evoq_retry_strategy:exponential(100, 10000),

    %% Delay = Base * 2^(Attempt-1)
    ?assertEqual(100, evoq_retry_strategy:next_delay(Strategy, 1)),   %% 100 * 2^0 = 100
    ?assertEqual(200, evoq_retry_strategy:next_delay(Strategy, 2)),   %% 100 * 2^1 = 200
    ?assertEqual(400, evoq_retry_strategy:next_delay(Strategy, 3)),   %% 100 * 2^2 = 400
    ?assertEqual(800, evoq_retry_strategy:next_delay(Strategy, 4)),   %% 100 * 2^3 = 800
    ?assertEqual(1600, evoq_retry_strategy:next_delay(Strategy, 5)),  %% 100 * 2^4 = 1600

    %% Should cap at max
    ?assertEqual(10000, evoq_retry_strategy:next_delay(Strategy, 10)), %% Would be 51200, capped at 10000
    ok.

retry_strategy_exponential_jitter_test(_Config) ->
    Strategy = evoq_retry_strategy:exponential_jitter(100, 10000),

    %% Run multiple times to verify jitter
    Delays = [evoq_retry_strategy:next_delay(Strategy, 3) || _ <- lists:seq(1, 10)],

    %% Base delay for attempt 3 is 400, with jitter 0.5-1.5x = 200-600
    %% (but capped at max 10000)
    lists:foreach(fun(Delay) ->
        ?assert(Delay >= 200),
        ?assert(Delay =< 600)
    end, Delays),

    %% Verify there's actual variation (not all same)
    UniqueDelays = lists:usort(Delays),
    ?assert(length(UniqueDelays) > 1),
    ok.

%%====================================================================
%% Dead Letter Tests
%%====================================================================

dead_letter_store_test(_Config) ->
    Event = #{event_type => <<"test.failed">>, data => #{id => 1}},
    Handler = test_failed_handler,
    FailureContext = evoq_failure_context:new(Handler, Event, {error, processing_failed}),

    %% Store the dead letter
    ok = evoq_dead_letter:store(Event, Handler, FailureContext),

    %% Verify count increased
    Count = evoq_dead_letter:count(),
    ?assert(Count >= 1),
    ok.

dead_letter_list_test(_Config) ->
    %% Store a few dead letters
    lists:foreach(fun(N) ->
        Event = #{event_type => <<"test.list">>, data => #{n => N}},
        FailureContext = evoq_failure_context:new(list_test_handler, Event, {error, test}),
        evoq_dead_letter:store(Event, list_test_handler, FailureContext)
    end, lists:seq(1, 3)),

    %% List all
    All = evoq_dead_letter:list(),
    ?assert(length(All) >= 3),

    %% List with filter
    FilteredByHandler = evoq_dead_letter:list(#{handler => list_test_handler}),
    ?assert(length(FilteredByHandler) >= 3),

    %% List with limit
    Limited = evoq_dead_letter:list(#{limit => 2}),
    ?assertEqual(2, length(Limited)),
    ok.

dead_letter_retry_test(_Config) ->
    Event = #{event_type => <<"test.retry">>, data => #{retry => true}},
    Handler = retry_test_handler,
    FailureContext = evoq_failure_context:new(Handler, Event, {error, will_retry}),

    ok = evoq_dead_letter:store(Event, Handler, FailureContext),

    %% Get the stored entry
    Entries = evoq_dead_letter:list(#{handler => Handler}),
    ?assert(length(Entries) >= 1),

    %% Get the first matching entry
    [#evoq_dead_letter{id = Id} | _] = Entries,

    %% Retry returns the event and handler
    {ok, ReturnedEvent, ReturnedHandler} = evoq_dead_letter:retry(Id),
    ?assertEqual(Event, ReturnedEvent),
    ?assertEqual(Handler, ReturnedHandler),

    %% Delete after "successful" retry
    ok = evoq_dead_letter:delete(Id),

    %% Verify deleted
    ?assertEqual({error, not_found}, evoq_dead_letter:get(Id)),
    ok.

%%====================================================================
%% Error Handler Tests
%%====================================================================

error_handler_default_action_test(_Config) ->
    Event = #{event_type => <<"test">>, data => #{}},

    %% First attempt - should retry
    Context1 = evoq_failure_context:new(test_handler, Event, {error, test}),
    Action1 = evoq_error_handler:default_action(test_handler, Context1),
    ?assertMatch({retry, _Delay}, Action1),

    %% After max retries - should dead letter
    Context5 = lists:foldl(fun(_, C) ->
        evoq_failure_context:increment(C)
    end, Context1, lists:seq(1, 5)),

    Action5 = evoq_error_handler:default_action(test_handler, Context5),
    ?assertEqual({dead_letter, max_retries_exceeded}, Action5),
    ok.

%%====================================================================
%% Consistency Tests
%%====================================================================

consistency_wait_empty_test(_Config) ->
    %% Wait with no specific handlers returns immediately
    Result = evoq_consistency:wait_for(
        test_store,
        <<"test-aggregate">>,
        1,
        #{handlers => [], timeout => 100}
    ),
    ?assertEqual(ok, Result),
    ok.

consistency_acknowledge_test(_Config) ->
    %% Start a waiter process
    StoreId = test_store,
    AggregateId = <<"test-ack-aggregate">>,
    Version = 1,
    TestPid = self(),

    %% Spawn a waiter
    _WaiterPid = spawn(fun() ->
        Result = evoq_consistency:wait_for(
            StoreId,
            AggregateId,
            Version,
            #{handlers => [test_handler], timeout => 5000}
        ),
        TestPid ! {wait_result, Result}
    end),

    %% Give waiter time to register
    timer:sleep(50),

    %% Acknowledge from handler
    ok = evoq_consistency:acknowledge(test_handler, StoreId, AggregateId, Version),

    %% Wait for result
    receive
        {wait_result, Result} ->
            ?assertEqual(ok, Result)
    after 1000 ->
        ct:fail("Waiter did not receive acknowledgment")
    end,
    ok.
