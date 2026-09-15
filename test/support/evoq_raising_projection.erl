%% @doc Test support projection whose project/4 raises on one designated
%% event. Proves a raising projection does not crash its process and lose
%% every event queued behind the failed one. Writes each projected item
%% into an ETS read model the test can read back.
-module(evoq_raising_projection).
-behaviour(evoq_projection).

-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"raise_proj_evt_v1">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, RM}.

project(#{event_type := <<"raise_proj_evt_v1">>, data := #{item_id := <<"boom">>}},
        _Metadata, _State, _RM) ->
    error(deliberate_projection_crash);
project(#{event_type := <<"raise_proj_evt_v1">>, data := #{item_id := ItemId}},
        _Metadata, State, RM) ->
    {ok, RM2} = evoq_read_model:put({item, ItemId}, #{id => ItemId}, RM),
    {ok, State, RM2};
project(_Event, _Metadata, State, RM) ->
    {ok, State, RM}.
