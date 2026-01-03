%% @doc Command router for evoq.
%%
%% Routes commands to the appropriate aggregate based on aggregate_type
%% and aggregate_id. Uses the dispatcher for middleware and execution.
%%
%% @author rgfaber
-module(evoq_router).

-include("evoq.hrl").

%% API
-export([dispatch/1, dispatch/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Dispatch a command with default options.
-spec dispatch(#evoq_command{}) -> {ok, non_neg_integer(), [map()]} | {error, term()}.
dispatch(Command) ->
    dispatch(Command, #{}).

%% @doc Dispatch a command with options.
%%
%% Options:
%% - consistency: eventual | strong | {handlers, [atom()]}
%% - timeout: pos_integer() (milliseconds)
%% - expected_version: integer() (-1 for any)
%% - middleware: [atom()] (additional middleware)
%%
-spec dispatch(#evoq_command{}, map()) -> {ok, non_neg_integer(), [map()]} | {error, term()}.
dispatch(Command, Opts) ->
    %% Validate the command first
    case evoq_command:validate(Command) of
        ok ->
            evoq_dispatcher:dispatch(Command, Opts);
        {error, _Reason} = Error ->
            Error
    end.
