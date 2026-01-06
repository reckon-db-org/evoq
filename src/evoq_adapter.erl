%% @doc Event store adapter behavior for evoq
%%
%% Defines the interface for event store operations. Implementations
%% provide the actual connection to an event store backend.
%%
%% == Implementing an Adapter ==
%%
%% ```
%% -module(my_adapter).
%% -behaviour(evoq_adapter).
%%
%% append(StoreId, StreamId, ExpectedVersion, Events) ->
%%     %% Implementation here
%%     {ok, NewVersion}.
%% '''
%%
%% == Configuration ==
%%
%% Set the adapter in application config:
%%
%% ```
%% {evoq, [
%%     {event_store_adapter, my_adapter}
%% ]}
%% '''
%%
%% @author rgfaber

-module(evoq_adapter).

-include_lib("evoq/include/evoq_types.hrl").

%%====================================================================
%% Callback Definitions
%%====================================================================

%% Append events to a stream with expected version check.
%%
%% Expected version semantics:
%%   -1 (NO_STREAM)    - Stream must not exist (first write)
%%   -2 (ANY_VERSION)  - No version check, always append
%%   N >= 0            - Stream version must equal N
%%
%% Returns {ok, NewVersion} on success or {error, Reason} on failure.
-callback append(StoreId :: atom(),
                 StreamId :: binary(),
                 ExpectedVersion :: integer(),
                 Events :: [map()]) ->
    {ok, non_neg_integer()} | {error, term()}.

%% Read events from a stream.
%%
%% Parameters:
%%   StoreId      - The store identifier
%%   StreamId     - The stream identifier
%%   StartVersion - Starting version (0-based)
%%   Count        - Maximum number of events to read
%%   Direction    - forward or backward
%%
%% Returns {ok, [Event]} or {error, Reason}
-callback read(StoreId :: atom(),
               StreamId :: binary(),
               StartVersion :: non_neg_integer(),
               Count :: pos_integer(),
               Direction :: forward | backward) ->
    {ok, [evoq_event()]} | {error, term()}.

%% Read all events from a stream.
-callback read_all(StoreId :: atom(),
                   StreamId :: binary(),
                   Direction :: forward | backward) ->
    {ok, [evoq_event()]} | {error, term()}.

%% Read events by event types across all streams.
%%
%% Uses native filtering capabilities to efficiently query events
%% by their type without loading all events into memory.
-callback read_by_event_types(StoreId :: atom(),
                              EventTypes :: [binary()],
                              BatchSize :: pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.

%% Get current version of a stream.
%%
%% Returns:
%%   -1    - if stream doesn't exist or is empty
%%   N >= 0 - representing the version of the latest event
-callback version(StoreId :: atom(), StreamId :: binary()) ->
    integer().

%% Check if a stream exists.
-callback exists(StoreId :: atom(), StreamId :: binary()) ->
    boolean().

%% List all streams in the store.
-callback list_streams(StoreId :: atom()) ->
    {ok, [binary()]} | {error, term()}.

%% Delete a stream and all its events.
-callback delete_stream(StoreId :: atom(), StreamId :: binary()) ->
    ok | {error, term()}.
