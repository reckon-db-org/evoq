%% @doc A middleware that overwrites a finished dispatch's answer with something
%% the router's specs do not describe (evoq#47).
%%
%% `after_dispatch' runs after the store has accepted the command. A middleware
%% that responds there without halting still replaces the response the router
%% recorded -- `keep_response_if_erased/2' only puts it back when the response is
%% `undefined' -- so answering `ok' hands the caller a shape no clause of its
%% spec admits, about a command that really did run.
-module(evoq_middleware_after_odd).

-behaviour(evoq_middleware).

-export([after_dispatch/1]).

after_dispatch(Pipeline) ->
    evoq_middleware:respond(ok, Pipeline).
