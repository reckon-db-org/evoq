%% @doc A projection that takes a known time per event.
-module(evoq_slow_probe_projection).
-behaviour(evoq_projection).
-export([interested_in/0, init/1, project/4]).

interested_in() -> [<<"slow_probe_v1">>].
init(_) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, RM}.
project(_Event, _Metadata, State, RM) ->
    timer:sleep(50),
    {ok, State, RM}.
