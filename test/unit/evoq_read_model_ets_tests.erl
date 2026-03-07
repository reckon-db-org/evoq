%%% @doc Tests for evoq_read_model_ets.
-module(evoq_read_model_ets_tests).
-include_lib("eunit/include/eunit.hrl").

%% -- Anonymous table: basic CRUD --

anonymous_crud_test() ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    %% Put
    {ok, RM2} = evoq_read_model:put(<<"k1">>, #{name => <<"alice">>}, RM),
    %% Get
    {ok, #{name := <<"alice">>}} = evoq_read_model:get(<<"k1">>, RM2),
    %% Not found
    {error, not_found} = evoq_read_model:get(<<"k2">>, RM2),
    %% Delete
    {ok, RM3} = evoq_read_model:delete(<<"k1">>, RM2),
    {error, not_found} = evoq_read_model:get(<<"k1">>, RM3).

%% -- Anonymous table: list all --

anonymous_list_all_test() ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, RM2} = evoq_read_model:put(<<"a">>, 1, RM),
    {ok, RM3} = evoq_read_model:put(<<"b">>, 2, RM2),
    {ok, Items} = evoq_read_model:list(all, RM3),
    ?assertEqual(2, length(Items)).

%% -- Anonymous table: clear --

anonymous_clear_test() ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, RM2} = evoq_read_model:put(<<"x">>, 42, RM),
    {ok, RM3} = evoq_read_model:clear(RM2),
    {ok, []} = evoq_read_model:list(all, RM3).

%% -- Named table: shared across instances --

shared_named_table_test() ->
    Name = test_shared_table,
    cleanup_table(Name),
    %% First instance creates the table
    {ok, RM1} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    %% Second instance joins the same table (no crash)
    {ok, RM2} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    %% Write from instance 1
    {ok, _} = evoq_read_model:put(<<"from_1">>, first, RM1),
    %% Read from instance 2
    {ok, first} = evoq_read_model:get(<<"from_1">>, RM2),
    %% Write from instance 2
    {ok, _} = evoq_read_model:put(<<"from_2">>, second, RM2),
    %% Read from instance 1
    {ok, second} = evoq_read_model:get(<<"from_2">>, RM1),
    cleanup_table(Name).

%% -- Named table: data visible across instances --

shared_list_sees_all_writes_test() ->
    Name = test_shared_list,
    cleanup_table(Name),
    {ok, RM1} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    {ok, RM2} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    {ok, _} = evoq_read_model:put(<<"a">>, 1, RM1),
    {ok, _} = evoq_read_model:put(<<"b">>, 2, RM2),
    {ok, Items} = evoq_read_model:list(all, RM1),
    ?assertEqual(2, length(Items)),
    cleanup_table(Name).

%% -- Named table: overwrite by same key --

shared_upsert_test() ->
    Name = test_shared_upsert,
    cleanup_table(Name),
    {ok, RM1} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    {ok, RM2} = evoq_read_model:new(evoq_read_model_ets, #{name => Name}),
    {ok, _} = evoq_read_model:put(<<"k">>, v1, RM1),
    {ok, _} = evoq_read_model:put(<<"k">>, v2, RM2),
    {ok, v2} = evoq_read_model:get(<<"k">>, RM1),
    cleanup_table(Name).

%% -- Binary prefix matching --

binary_prefix_test() ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, RM2} = evoq_read_model:put(<<"user:1">>, a, RM),
    {ok, RM3} = evoq_read_model:put(<<"user:2">>, b, RM2),
    {ok, RM4} = evoq_read_model:put(<<"order:1">>, c, RM3),
    {ok, Users} = evoq_read_model:list(<<"user:">>, RM4),
    ?assertEqual(2, length(Users)).

%% -- Helpers --

cleanup_table(Name) ->
    case ets:whereis(Name) of
        undefined -> ok;
        _Tid -> ets:delete(Name)
    end.
