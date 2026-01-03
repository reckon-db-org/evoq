%% @doc Default aggregate lifespan implementation.
%%
%% Provides sensible defaults for aggregate lifecycle:
%% - 30-minute idle timeout
%% - 5-minute timeout on errors
%% - Automatic snapshot on passivation
%%
%% This prevents the memory explosion that occurs when aggregates
%% live indefinitely (as in Commanded's default lifespan).
%%
%% @author rgfaber
-module(evoq_aggregate_lifespan_default).
-behaviour(evoq_aggregate_lifespan).

-include("evoq.hrl").

%% Behavior callbacks
-export([after_event/1, after_command/1, after_error/1]).
-export([on_timeout/1, on_passivate/1]).

%%====================================================================
%% Behavior callbacks
%%====================================================================

%% @doc Return timeout after processing an event.
%% Resets the idle timer to the default 30 minutes.
-spec after_event(map()) -> evoq_aggregate_lifespan:action().
after_event(_Event) ->
    get_idle_timeout().

%% @doc Return timeout after processing a command.
%% Resets the idle timer to the default 30 minutes.
-spec after_command(map()) -> evoq_aggregate_lifespan:action().
after_command(_Command) ->
    get_idle_timeout().

%% @doc Return timeout after an error.
%% Uses a shorter timeout (5 minutes) to allow faster recovery.
-spec after_error(term()) -> evoq_aggregate_lifespan:action().
after_error(_Error) ->
    300000.  %% 5 minutes

%% @doc Handle timeout by passivating with snapshot.
-spec on_timeout(term()) -> {snapshot, passivate}.
on_timeout(_State) ->
    {snapshot, passivate}.

%% @doc Return snapshot data on passivation.
-spec on_passivate(term()) -> {ok, term()}.
on_passivate(State) ->
    {ok, State}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
get_idle_timeout() ->
    application:get_env(evoq, idle_timeout, ?DEFAULT_IDLE_TIMEOUT).
