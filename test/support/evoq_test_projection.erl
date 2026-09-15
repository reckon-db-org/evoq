%% @doc Test support projection. Proves the router's async {deliver, ...}
%% cast actually reaches project/4 and mutates the read model -- the
%% regression the slice-1 async switch would otherwise introduce, since a
%% projection registers in the same event-type registry as a handler but
%% must also understand the cast. Writes each projected item into an ETS
%% read model the test can read back.
-module(evoq_test_projection).
-behaviour(evoq_projection).

-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"proj_evt_v1">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, RM}.

project(#{event_type := <<"proj_evt_v1">>, data := #{item_id := ItemId}},
        _Metadata, State, RM) ->
    {ok, RM2} = evoq_read_model:put({item, ItemId}, #{id => ItemId}, RM),
    {ok, State, RM2};
project(_Event, _Metadata, State, RM) ->
    {ok, State, RM}.
