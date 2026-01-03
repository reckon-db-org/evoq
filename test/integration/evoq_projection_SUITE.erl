%% @doc Integration tests for projections and read models.
%%
%% Tests:
%% - Read model ETS implementation
%% - Projection behavior
%% - Checkpoint persistence
%% - Idempotent event processing
%%
%% @author Reckon-DB
-module(evoq_projection_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    read_model_ets_init_test/1,
    read_model_ets_put_get_test/1,
    read_model_ets_delete_test/1,
    read_model_ets_list_test/1,
    read_model_ets_clear_test/1,
    read_model_wrapper_test/1,
    checkpoint_store_save_load_test/1,
    checkpoint_store_delete_test/1,
    projection_start_test/1,
    projection_notify_test/1,
    projection_idempotency_test/1,
    projection_checkpoint_test/1
]).

%% Test Projection module
-behaviour(evoq_projection).
-export([interested_in/0, init/1, project/4]).

%%====================================================================
%% Test Projection Callbacks
%%====================================================================

interested_in() ->
    [<<"ItemAdded">>, <<"ItemRemoved">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{items_count => 0}, RM}.

project(#{event_type := <<"ItemAdded">>, data := #{item_id := ItemId}}, _Metadata, State, RM) ->
    %% Add item to read model
    {ok, RM2} = evoq_read_model:put({item, ItemId}, #{id => ItemId, status => active}, RM),
    NewCount = maps:get(items_count, State, 0) + 1,
    {ok, State#{items_count => NewCount}, RM2};

project(#{event_type := <<"ItemRemoved">>, data := #{item_id := ItemId}}, _Metadata, State, RM) ->
    %% Remove item from read model
    {ok, RM2} = evoq_read_model:delete({item, ItemId}, RM),
    NewCount = max(0, maps:get(items_count, State, 0) - 1),
    {ok, State#{items_count => NewCount}, RM2};

project(_Event, _Metadata, State, RM) ->
    {skip, State, RM}.

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, read_model_tests},
        {group, checkpoint_tests},
        {group, projection_tests}
    ].

groups() ->
    [
        {read_model_tests, [sequence], [
            read_model_ets_init_test,
            read_model_ets_put_get_test,
            read_model_ets_delete_test,
            read_model_ets_list_test,
            read_model_ets_clear_test,
            read_model_wrapper_test
        ]},
        {checkpoint_tests, [sequence], [
            checkpoint_store_save_load_test,
            checkpoint_store_delete_test
        ]},
        {projection_tests, [sequence], [
            projection_start_test,
            projection_notify_test,
            projection_idempotency_test,
            projection_checkpoint_test
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
%% Read Model Tests
%%====================================================================

read_model_ets_init_test(_Config) ->
    {ok, State} = evoq_read_model_ets:init(#{}),
    %% State is an internal record/tuple
    ?assert(is_tuple(State)),
    ok.

read_model_ets_put_get_test(_Config) ->
    {ok, State} = evoq_read_model_ets:init(#{}),

    %% Put a value
    {ok, State2} = evoq_read_model_ets:put(key1, value1, State),

    %% Get it back
    ?assertEqual({ok, value1}, evoq_read_model_ets:get(key1, State2)),

    %% Non-existent key
    ?assertEqual({error, not_found}, evoq_read_model_ets:get(nonexistent, State2)),
    ok.

read_model_ets_delete_test(_Config) ->
    {ok, State} = evoq_read_model_ets:init(#{}),

    %% Put and delete
    {ok, State2} = evoq_read_model_ets:put(key2, value2, State),
    ?assertEqual({ok, value2}, evoq_read_model_ets:get(key2, State2)),

    {ok, State3} = evoq_read_model_ets:delete(key2, State2),
    ?assertEqual({error, not_found}, evoq_read_model_ets:get(key2, State3)),
    ok.

read_model_ets_list_test(_Config) ->
    {ok, State} = evoq_read_model_ets:init(#{}),

    %% Add some values
    {ok, State2} = evoq_read_model_ets:put(<<"prefix:a">>, 1, State),
    {ok, State3} = evoq_read_model_ets:put(<<"prefix:b">>, 2, State2),
    {ok, State4} = evoq_read_model_ets:put(<<"other:c">>, 3, State3),

    %% List all
    {ok, All} = evoq_read_model_ets:list(all, State4),
    ?assertEqual(3, length(All)),

    %% List with prefix
    {ok, Prefixed} = evoq_read_model_ets:list(<<"prefix:">>, State4),
    ?assertEqual(2, length(Prefixed)),
    ok.

read_model_ets_clear_test(_Config) ->
    {ok, State} = evoq_read_model_ets:init(#{}),

    %% Add values
    {ok, State2} = evoq_read_model_ets:put(key1, value1, State),
    {ok, State3} = evoq_read_model_ets:put(key2, value2, State2),

    %% Clear
    {ok, State4} = evoq_read_model_ets:clear(State3),

    %% Verify empty
    ?assertEqual({error, not_found}, evoq_read_model_ets:get(key1, State4)),
    ?assertEqual({error, not_found}, evoq_read_model_ets:get(key2, State4)),
    ok.

read_model_wrapper_test(_Config) ->
    %% Test the evoq_read_model wrapper API
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),

    %% Put
    {ok, RM2} = evoq_read_model:put(wrapper_key, wrapper_value, RM),

    %% Get
    ?assertEqual({ok, wrapper_value}, evoq_read_model:get(wrapper_key, RM2)),

    %% Checkpoint
    ?assertEqual(0, evoq_read_model:get_checkpoint(RM2)),
    RM3 = evoq_read_model:set_checkpoint(100, RM2),
    ?assertEqual(100, evoq_read_model:get_checkpoint(RM3)),

    %% Delete
    {ok, RM4} = evoq_read_model:delete(wrapper_key, RM3),
    ?assertEqual({error, not_found}, evoq_read_model:get(wrapper_key, RM4)),
    ok.

%%====================================================================
%% Checkpoint Tests
%%====================================================================

checkpoint_store_save_load_test(_Config) ->
    %% Save checkpoint
    ok = evoq_checkpoint_store_ets:save(test_projection, 42),

    %% Load it back
    ?assertEqual({ok, 42}, evoq_checkpoint_store_ets:load(test_projection)),

    %% Non-existent projection
    ?assertEqual({error, not_found}, evoq_checkpoint_store_ets:load(nonexistent_projection)),
    ok.

checkpoint_store_delete_test(_Config) ->
    %% Save and delete
    ok = evoq_checkpoint_store_ets:save(delete_test, 100),
    ?assertEqual({ok, 100}, evoq_checkpoint_store_ets:load(delete_test)),

    ok = evoq_checkpoint_store_ets:delete(delete_test),
    ?assertEqual({error, not_found}, evoq_checkpoint_store_ets:load(delete_test)),
    ok.

%%====================================================================
%% Projection Tests
%%====================================================================

projection_start_test(_Config) ->
    %% Start a projection
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{}, #{
        checkpoint_store => evoq_checkpoint_store_ets
    }),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),

    %% Check event types
    EventTypes = evoq_projection:get_event_types(Pid),
    ?assertEqual([<<"ItemAdded">>, <<"ItemRemoved">>], EventTypes),

    %% Cleanup
    gen_server:stop(Pid),
    ok.

projection_notify_test(_Config) ->
    %% Start a projection
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{}, #{}),

    %% Add an item
    Event = #{
        event_type => <<"ItemAdded">>,
        data => #{item_id => <<"item-001">>}
    },
    Metadata = #{version => 1, stream_id => <<"test-stream">>},

    ok = evoq_projection:notify(Pid, <<"ItemAdded">>, Event, Metadata),

    %% Verify item was added to read model
    RM = evoq_projection:get_read_model(Pid),
    ?assertEqual({ok, #{id => <<"item-001">>, status => active}},
                 evoq_read_model:get({item, <<"item-001">>}, RM)),

    %% Cleanup
    gen_server:stop(Pid),
    ok.

projection_idempotency_test(_Config) ->
    %% Start a projection
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{}, #{}),

    %% First, add an event to move checkpoint forward
    Event1 = #{
        event_type => <<"ItemAdded">>,
        data => #{item_id => <<"first-item">>}
    },
    ok = evoq_projection:notify(Pid, <<"ItemAdded">>, Event1, #{version => 5}),

    %% Get current checkpoint (should be 5)
    Checkpoint1 = evoq_projection:get_checkpoint(Pid),
    ?assertEqual(5, Checkpoint1),

    %% Try to replay an old event (version <= checkpoint)
    OldEvent = #{
        event_type => <<"ItemAdded">>,
        data => #{item_id => <<"old-item">>}
    },

    ok = evoq_projection:notify(Pid, <<"ItemAdded">>, OldEvent, #{version => 3}),

    %% The old item should NOT be added (idempotency)
    RM = evoq_projection:get_read_model(Pid),
    ?assertEqual({error, not_found}, evoq_read_model:get({item, <<"old-item">>}, RM)),

    %% Checkpoint should be unchanged
    Checkpoint2 = evoq_projection:get_checkpoint(Pid),
    ?assertEqual(Checkpoint1, Checkpoint2),

    %% Cleanup
    gen_server:stop(Pid),
    ok.

projection_checkpoint_test(_Config) ->
    %% Start a projection with checkpoint store
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{}, #{
        checkpoint_store => evoq_checkpoint_store_ets
    }),

    %% Get current checkpoint (should be 0)
    Checkpoint1 = evoq_projection:get_checkpoint(Pid),
    ?assertEqual(0, Checkpoint1),

    %% Add a new item
    Event = #{
        event_type => <<"ItemAdded">>,
        data => #{item_id => <<"item-checkpoint-test">>}
    },

    ok = evoq_projection:notify(Pid, <<"ItemAdded">>, Event, #{version => 10}),

    %% Checkpoint should be updated
    Checkpoint2 = evoq_projection:get_checkpoint(Pid),
    ?assertEqual(10, Checkpoint2),

    %% Verify checkpoint was persisted
    ?assertEqual({ok, 10}, evoq_checkpoint_store_ets:load(?MODULE)),

    %% Cleanup
    gen_server:stop(Pid),
    ok.
