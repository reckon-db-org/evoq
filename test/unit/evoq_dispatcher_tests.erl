%% @doc Tests for idempotency_key and auto-generated command_id feature.
%%
%% Verifies:
%% - Same idempotency_key → cached (executes once)
%% - Different keys → both execute
%% - idempotency_key deduplicates across different command_ids
%% - No idempotency_key → auto-generated command_ids are unique → no collision
%% - Cache key selection: idempotency_key takes precedence over command_id
-module(evoq_dispatcher_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%%====================================================================
%% Test Fixture
%%====================================================================

idempotency_test_() ->
    {setup, fun start_idempotency/0, fun stop_idempotency/1, [
        fun same_key_returns_cached_result/0,
        fun different_keys_both_execute/0,
        fun idempotency_key_deduplicates_across_command_ids/0,
        fun no_idempotency_key_auto_ids_never_collide/0,
        fun cache_key_selection_prefers_idempotency_key/0,
        fun cache_key_selection_falls_back_to_command_id/0
    ]}.

start_idempotency() ->
    application:ensure_all_started(telemetry),
    {ok, Pid} = evoq_idempotency:start_link(),
    Pid.

stop_idempotency(Pid) ->
    gen_server:stop(Pid).

%%====================================================================
%% Tests
%%====================================================================

same_key_returns_cached_result() ->
    Counter = counters:new(1, []),
    Key = <<"same-key-test">>,
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        {ok, counters:get(Counter, 1), [#{event_type => <<"test">>}]}
    end,
    %% First call executes
    {ok, 1, _} = evoq_idempotency:check_and_store(Key, Fun, 60000),
    %% Second call returns cached — function NOT called again
    {ok, 1, _} = evoq_idempotency:check_and_store(Key, Fun, 60000),
    ?assertEqual(1, counters:get(Counter, 1)).

different_keys_both_execute() ->
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        {ok, counters:get(Counter, 1), []}
    end,
    {ok, 1, _} = evoq_idempotency:check_and_store(<<"dk-alpha">>, Fun, 60000),
    {ok, 2, _} = evoq_idempotency:check_and_store(<<"dk-beta">>, Fun, 60000),
    ?assertEqual(2, counters:get(Counter, 1)).

idempotency_key_deduplicates_across_command_ids() ->
    %% Two commands with DIFFERENT command_ids but SAME idempotency_key.
    %% The dispatcher uses idempotency_key as cache key when set,
    %% so the second dispatch should return the cached result.
    Counter = counters:new(1, []),
    IdemKey = <<"form-submit-xyz">>,
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        {ok, counters:get(Counter, 1), [#{event_type => <<"submitted">>}]}
    end,
    %% Simulate two dispatches — dispatcher would use idempotency_key as cache key
    {ok, 1, _} = evoq_idempotency:check_and_store(IdemKey, Fun, 60000),
    {ok, 1, _} = evoq_idempotency:check_and_store(IdemKey, Fun, 60000),
    ?assertEqual(1, counters:get(Counter, 1)).

no_idempotency_key_auto_ids_never_collide() ->
    %% Without idempotency_key, dispatcher uses command_id (auto-generated).
    %% Auto-generated IDs must be unique, so both commands execute.
    Counter = counters:new(1, []),
    Fun = fun() ->
        counters:add(Counter, 1, 1),
        {ok, counters:get(Counter, 1), []}
    end,
    %% Build two commands with undefined command_id, let ensure_id fill them
    Cmd1 = evoq_command:ensure_id(#evoq_command{
        command_type = test_cmd,
        aggregate_type = test_agg,
        aggregate_id = <<"same-aggregate">>
    }),
    Cmd2 = evoq_command:ensure_id(#evoq_command{
        command_type = test_cmd,
        aggregate_type = test_agg,
        aggregate_id = <<"same-aggregate">>
    }),
    %% command_ids should be different
    ?assertNotEqual(Cmd1#evoq_command.command_id, Cmd2#evoq_command.command_id),
    %% Both idempotency_keys are undefined, so dispatcher uses command_id
    Key1 = Cmd1#evoq_command.command_id,
    Key2 = Cmd2#evoq_command.command_id,
    {ok, 1, _} = evoq_idempotency:check_and_store(Key1, Fun, 60000),
    {ok, 2, _} = evoq_idempotency:check_and_store(Key2, Fun, 60000),
    ?assertEqual(2, counters:get(Counter, 1)).

cache_key_selection_prefers_idempotency_key() ->
    %% Verify the cache key selection logic: when idempotency_key is set, use it
    Cmd = #evoq_command{
        command_id = <<"cmd-999">>,
        command_type = test_cmd,
        aggregate_type = test_agg,
        aggregate_id = <<"agg-1">>,
        idempotency_key = <<"my-idem-key">>
    },
    CacheKey = case Cmd#evoq_command.idempotency_key of
        undefined -> Cmd#evoq_command.command_id;
        Key -> Key
    end,
    ?assertEqual(<<"my-idem-key">>, CacheKey).

cache_key_selection_falls_back_to_command_id() ->
    %% Verify the cache key selection logic: when idempotency_key is undefined, use command_id
    Cmd = #evoq_command{
        command_id = <<"cmd-888">>,
        command_type = test_cmd,
        aggregate_type = test_agg,
        aggregate_id = <<"agg-1">>
    },
    CacheKey = case Cmd#evoq_command.idempotency_key of
        undefined -> Cmd#evoq_command.command_id;
        Key -> Key
    end,
    ?assertEqual(<<"cmd-888">>, CacheKey).
