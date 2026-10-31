%% @doc A middleware that halts after the command has run and leaves the
%% pipeline with no response at all (evoq#45).
%%
%% The command has already been accepted by the store at this point, and the
%% router had put its `{ok, Version, Events}' on the pipeline. A halt is a
%% decision to stop the chain, not a licence to erase the result the command
%% produced.
-module(evoq_middleware_after_halt_blank).

-behaviour(evoq_middleware).

-export([after_dispatch/1, after_failure/1]).

after_dispatch(Pipeline) ->
    evoq_middleware:respond(undefined, evoq_middleware:halt(Pipeline)).

after_failure(Pipeline) ->
    evoq_middleware:respond(undefined, evoq_middleware:halt(Pipeline)).
