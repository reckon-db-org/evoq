%% @doc A middleware that halts and answers something the router's specs do not
%% describe (evoq#47).
%%
%% `evoq_middleware:respond/2' takes any term. A halt that answers `ok' stops the
%% command and says "success" in a shape no caller of `dispatch/2' or
%% `dispatch_with_state/2' can match, which is either a crash or a lie at the
%% caller. The router refuses it by name instead of passing it through.
-module(evoq_middleware_halt_odd).

-behaviour(evoq_middleware).

-export([before_dispatch/1]).

before_dispatch(Pipeline) ->
    evoq_middleware:respond(ok, evoq_middleware:halt(Pipeline)).
