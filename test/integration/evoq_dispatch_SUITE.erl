%% @doc Integration tests for command dispatch.
%%
%% Tests the full dispatch flow:
%% - Command creation and validation
%% - Middleware pipeline execution
%% - Idempotency checking
%% - Router to aggregate dispatch
%%
%% @author Reckon-DB
-module(evoq_dispatch_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    command_new_test/1,
    command_validate_test/1,
    command_validate_missing_fields_test/1,
    middleware_before_dispatch_test/1,
    middleware_after_dispatch_test/1,
    middleware_halt_pipeline_test/1,
    idempotency_first_call_test/1,
    idempotency_duplicate_call_test/1,
    idempotency_expired_test/1,
    pipeline_assign_test/1,
    pipeline_respond_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, command_tests},
        {group, middleware_tests},
        {group, idempotency_tests},
        {group, pipeline_tests}
    ].

groups() ->
    [
        {command_tests, [sequence], [
            command_new_test,
            command_validate_test,
            command_validate_missing_fields_test
        ]},
        {middleware_tests, [sequence], [
            middleware_before_dispatch_test,
            middleware_after_dispatch_test,
            middleware_halt_pipeline_test
        ]},
        {idempotency_tests, [sequence], [
            idempotency_first_call_test,
            idempotency_duplicate_call_test,
            idempotency_expired_test
        ]},
        {pipeline_tests, [sequence], [
            pipeline_assign_test,
            pipeline_respond_test
        ]}
    ].

init_per_suite(Config) ->
    %% Start the evoq application (which starts idempotency, etc.)
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
%% Command tests
%%====================================================================

command_new_test(_Config) ->
    Command = evoq_command:new(
        test_command,
        test_aggregate,
        <<"agg-123">>,
        #{amount => 100}
    ),

    ?assertMatch(#evoq_command{
        command_type = test_command,
        aggregate_type = test_aggregate,
        aggregate_id = <<"agg-123">>,
        payload = #{amount := 100}
    }, Command),

    %% Check auto-generated fields
    ?assertNotEqual(undefined, Command#evoq_command.command_id),
    ?assertEqual(32, byte_size(Command#evoq_command.command_id)),
    ok.

command_validate_test(_Config) ->
    Command = evoq_command:new(
        test_command,
        test_aggregate,
        <<"agg-123">>,
        #{amount => 100}
    ),

    ?assertEqual(ok, evoq_command:validate(Command)),
    ok.

command_validate_missing_fields_test(_Config) ->
    %% Missing aggregate_id
    Command1 = #evoq_command{
        command_id = crypto:strong_rand_bytes(16),
        command_type = test_command,
        aggregate_type = test_aggregate,
        aggregate_id = undefined,
        payload = #{}
    },
    ?assertEqual({error, missing_aggregate_id}, evoq_command:validate(Command1)),

    %% Missing command_type
    Command2 = #evoq_command{
        command_id = crypto:strong_rand_bytes(16),
        command_type = undefined,
        aggregate_type = test_aggregate,
        aggregate_id = <<"agg-123">>,
        payload = #{}
    },
    ?assertEqual({error, missing_command_type}, evoq_command:validate(Command2)),

    %% Missing aggregate_type
    Command3 = #evoq_command{
        command_id = crypto:strong_rand_bytes(16),
        command_type = test_command,
        aggregate_type = undefined,
        aggregate_id = <<"agg-123">>,
        payload = #{}
    },
    ?assertEqual({error, missing_aggregate_type}, evoq_command:validate(Command3)),
    ok.

%%====================================================================
%% Middleware tests
%%====================================================================

middleware_before_dispatch_test(_Config) ->
    %% Create a test pipeline
    Command = evoq_command:new(test_cmd, test_agg, <<"id">>, #{}),
    Context = evoq_execution_context:new(Command, #{}),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },

    %% Run through empty middleware chain
    Result = evoq_middleware:chain(Pipeline, before_dispatch, []),

    ?assertMatch(#evoq_pipeline{halted = false}, Result),
    ok.

middleware_after_dispatch_test(_Config) ->
    Command = evoq_command:new(test_cmd, test_agg, <<"id">>, #{}),
    Context = evoq_execution_context:new(Command, #{}),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = {ok, 1, []}
    },

    %% Run through empty middleware chain
    Result = evoq_middleware:chain(Pipeline, after_dispatch, []),

    ?assertMatch(#evoq_pipeline{response = {ok, 1, []}}, Result),
    ok.

middleware_halt_pipeline_test(_Config) ->
    Command = evoq_command:new(test_cmd, test_agg, <<"id">>, #{}),
    Context = evoq_execution_context:new(Command, #{}),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },

    %% Test halt function
    HaltedPipeline = evoq_middleware:halt(Pipeline),
    ?assertEqual(true, evoq_middleware:halted(HaltedPipeline)),
    ?assertEqual(true, HaltedPipeline#evoq_pipeline.halted),
    ok.

%%====================================================================
%% Idempotency tests
%%====================================================================

idempotency_first_call_test(_Config) ->
    CommandId = crypto:strong_rand_bytes(16),

    %% First call should execute the function
    ExecuteCount = counters:new(1, []),
    Result = evoq_idempotency:check_and_store(CommandId, fun() ->
        counters:add(ExecuteCount, 1, 1),
        {ok, 1, [#{event_type => <<"test">>}]}
    end, 60000),

    ?assertEqual({ok, 1, [#{event_type => <<"test">>}]}, Result),
    ?assertEqual(1, counters:get(ExecuteCount, 1)),
    ok.

idempotency_duplicate_call_test(_Config) ->
    CommandId = crypto:strong_rand_bytes(16),

    %% First call
    ExecuteCount = counters:new(1, []),
    Result1 = evoq_idempotency:check_and_store(CommandId, fun() ->
        counters:add(ExecuteCount, 1, 1),
        {ok, 1, [#{event_type => <<"test">>}]}
    end, 60000),

    %% Second call with same command_id should return cached result
    Result2 = evoq_idempotency:check_and_store(CommandId, fun() ->
        counters:add(ExecuteCount, 1, 1),
        {ok, 2, [#{event_type => <<"different">>}]}
    end, 60000),

    %% Both should return the same result
    ?assertEqual(Result1, Result2),
    %% Function should only have been called once
    ?assertEqual(1, counters:get(ExecuteCount, 1)),
    ok.

idempotency_expired_test(_Config) ->
    CommandId = crypto:strong_rand_bytes(16),

    %% Store with very short TTL (1ms)
    evoq_idempotency:store(CommandId, {ok, 1, []}, 1),

    %% Wait for expiration
    timer:sleep(10),

    %% Lookup should return not_found
    Result = evoq_idempotency:lookup(CommandId),
    ?assertEqual(not_found, Result),
    ok.

%%====================================================================
%% Pipeline tests
%%====================================================================

pipeline_assign_test(_Config) ->
    Command = evoq_command:new(test_cmd, test_agg, <<"id">>, #{}),
    Context = evoq_execution_context:new(Command, #{}),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },

    %% Test assign
    Pipeline2 = evoq_middleware:assign(key1, value1, Pipeline),
    ?assertEqual(value1, evoq_middleware:get_assign(key1, Pipeline2)),
    ?assertEqual(undefined, evoq_middleware:get_assign(missing, Pipeline2)),
    ?assertEqual(default, evoq_middleware:get_assign(missing, Pipeline2, default)),

    %% Multiple assigns
    Pipeline3 = evoq_middleware:assign(key2, value2, Pipeline2),
    ?assertEqual(value1, evoq_middleware:get_assign(key1, Pipeline3)),
    ?assertEqual(value2, evoq_middleware:get_assign(key2, Pipeline3)),
    ok.

pipeline_respond_test(_Config) ->
    Command = evoq_command:new(test_cmd, test_agg, <<"id">>, #{}),
    Context = evoq_execution_context:new(Command, #{}),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },

    %% Test respond
    Pipeline2 = evoq_middleware:respond({ok, 1, []}, Pipeline),
    ?assertEqual({ok, 1, []}, evoq_middleware:get_response(Pipeline2)),
    ?assertEqual({ok, 1, []}, Pipeline2#evoq_pipeline.response),
    ok.
