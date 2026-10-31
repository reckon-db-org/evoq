%% @doc A middleware that halts the pipeline and says nothing else (evoq#41).
%%
%% `halt/1' and `respond/2' are separate calls on the pipeline, and nothing in
%% the behaviour requires them together. A middleware that only wants to stop the
%% command -- a maintenance window, a kill switch, a feature flag -- has no
%% reason to call `respond/2' at all.
-module(evoq_middleware_halt_only).

-behaviour(evoq_middleware).

-export([before_dispatch/1]).

before_dispatch(Pipeline) ->
    evoq_middleware:halt(Pipeline).
