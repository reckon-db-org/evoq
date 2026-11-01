%% @doc A middleware that halts and answers SUCCESS without running the command
%% (evoq#47).
%%
%% A `before_dispatch' halt may respond with anything, and `{ok, Version,
%% Events}' is a legitimate answer -- a cache, a replay, a policy that says "yes,
%% already done". Nothing runs: the call never reaches an aggregate, so there is
%% no post-command state to return. `dispatch_with_state/2' therefore answers this
%% middleware's 3-tuple as given rather than inventing a state.
-module(evoq_middleware_halt_success).

-behaviour(evoq_middleware).

-export([before_dispatch/1]).

-define(ANSWER, {ok, 0, []}).

before_dispatch(Pipeline) ->
    evoq_middleware:respond(?ANSWER, evoq_middleware:halt(Pipeline)).
