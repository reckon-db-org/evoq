%% @doc A projection on both `restart_a_v1' and `restart_b_v1' that records
%% each event it projects as {Type, N}: the shape that shows the backfill
%% registration-timing limit (see evoq_projection_restart_checkpoint_tests).
-module(evoq_restart_probe_ab_projection).
-behaviour(evoq_projection).
-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"restart_a_v1">>, <<"restart_b_v1">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, RM}.

project(#{event_type := Type, data := #{n := N}}, Metadata, State, RM) ->
    evoq_replay_probe:record(ab_projection, {Type, N}, Metadata),
    {ok, State, RM}.
