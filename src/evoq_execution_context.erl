%% @doc Execution context for command dispatch.
%%
%% Tracks command execution state through the middleware pipeline,
%% including retry attempts, consistency requirements, and metadata.
%%
%% @author rgfaber
-module(evoq_execution_context).

-include("evoq.hrl").

%% API
-export([new/1, new/2]).
-export([retry/1, can_retry/1]).
-export([get/2, put/3]).

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new execution context from a command.
-spec new(#evoq_command{}) -> #evoq_execution_context{}.
new(Command) ->
    new(Command, #{}).

%% @doc Create a new execution context with options.
%%
%% The store_id option determines which ReckonDB store to use.
%% If not specified, falls back to the application env configuration.
-spec new(#evoq_command{}, map()) -> #evoq_execution_context{}.
new(Command, Opts) ->
    StoreId = maps:get(store_id, Opts, application:get_env(evoq, store_id, default_store)),
    #evoq_execution_context{
        command_id = Command#evoq_command.command_id,
        causation_id = Command#evoq_command.causation_id,
        correlation_id = Command#evoq_command.correlation_id,
        aggregate_id = Command#evoq_command.aggregate_id,
        aggregate_type = Command#evoq_command.aggregate_type,
        store_id = StoreId,
        expected_version = maps:get(expected_version, Opts, -1),
        retry_attempts = maps:get(retry_attempts, Opts, ?DEFAULT_RETRY_ATTEMPTS),
        consistency = maps:get(consistency, Opts, eventual),
        timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
        metadata = Command#evoq_command.metadata
    }.

%% @doc Attempt to retry the command.
%% Returns {ok, NewContext} if retries remain, {error, too_many_attempts} otherwise.
-spec retry(#evoq_execution_context{}) ->
    {ok, #evoq_execution_context{}} | {error, too_many_attempts}.
retry(#evoq_execution_context{retry_attempts = 0}) ->
    {error, too_many_attempts};
retry(#evoq_execution_context{retry_attempts = N} = Context) ->
    {ok, Context#evoq_execution_context{retry_attempts = N - 1}}.

%% @doc Check if retries are available.
-spec can_retry(#evoq_execution_context{}) -> boolean().
can_retry(#evoq_execution_context{retry_attempts = N}) ->
    N > 0.

%% @doc Get a value from the context metadata.
-spec get(atom(), #evoq_execution_context{}) -> term() | undefined.
get(Key, #evoq_execution_context{metadata = Meta}) ->
    maps:get(Key, Meta, undefined).

%% @doc Put a value into the context metadata.
-spec put(atom(), term(), #evoq_execution_context{}) -> #evoq_execution_context{}.
put(Key, Value, #evoq_execution_context{metadata = Meta} = Context) ->
    Context#evoq_execution_context{metadata = Meta#{Key => Value}}.
