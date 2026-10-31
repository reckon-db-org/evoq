%% @doc A middleware that refuses every command, used to prove that a cold
%% module is still RUN and not skipped (evoq#39).
-module(evoq_middleware_deny_all).

-behaviour(evoq_middleware).

-export([before_dispatch/1]).

before_dispatch(Pipeline) ->
    evoq_middleware:respond({error, denied}, evoq_middleware:halt(Pipeline)).
