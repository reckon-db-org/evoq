%% @doc A middleware that acts only after the command has run, used to prove
%% that "this stage is not exported" is still a skip and not a refusal
%% (evoq#39). It exports one of the three optional callbacks and nothing else,
%% which is the shape the contract protects.
-module(evoq_middleware_after_only).

-behaviour(evoq_middleware).

-export([after_dispatch/1]).

after_dispatch(Pipeline) ->
    evoq_middleware:respond({ok, after_only}, Pipeline).
