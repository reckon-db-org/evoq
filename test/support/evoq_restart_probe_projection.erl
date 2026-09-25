%% @doc A projection on `restart_a_v1' that records every event it projects,
%% so a test can tell whether a restart skipped or repeated one.
-module(evoq_restart_probe_projection).
-behaviour(evoq_projection).
-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"restart_a_v1">>].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, RM}.

project(#{data := #{n := N}}, Metadata, State, RM) ->
    evoq_replay_probe:record(projection, N, Metadata),
    {ok, State, RM}.
