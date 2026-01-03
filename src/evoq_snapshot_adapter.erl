%% @doc Snapshot store adapter behavior for erl-evoq
%%
%% Defines the interface for snapshot operations. Snapshots are used
%% to optimize aggregate reconstruction by storing periodic state.
%%
%% @author Reckon-DB

-module(evoq_snapshot_adapter).

-include_lib("reckon_gater/include/esdb_gater_types.hrl").

%%====================================================================
%% Callback Definitions
%%====================================================================

%% Save a snapshot for a stream at a specific version.
%%
%% Parameters:
%%   StoreId  - The store identifier
%%   StreamId - The stream/aggregate identifier
%%   Version  - The stream version at which snapshot was taken
%%   Data     - The snapshot data (aggregate state)
%%   Metadata - Optional metadata (e.g., aggregate type, timestamp)
-callback save(StoreId :: atom(),
               StreamId :: binary(),
               Version :: non_neg_integer(),
               Data :: map() | binary(),
               Metadata :: map()) ->
    ok | {error, term()}.

%% Read the latest snapshot for a stream.
%%
%% Returns the most recent snapshot that exists for the stream.
%% Used during aggregate reconstruction to skip replaying all events.
-callback read(StoreId :: atom(), StreamId :: binary()) ->
    {ok, snapshot()} | {error, not_found | term()}.

%% Read a snapshot at a specific version.
%%
%% Returns the snapshot taken exactly at the specified version,
%% or error if no snapshot exists at that version.
-callback read_at_version(StoreId :: atom(),
                          StreamId :: binary(),
                          Version :: non_neg_integer()) ->
    {ok, snapshot()} | {error, not_found | term()}.

%% Delete all snapshots for a stream.
-callback delete(StoreId :: atom(), StreamId :: binary()) ->
    ok | {error, term()}.

%% Delete a specific snapshot version.
-callback delete_at_version(StoreId :: atom(),
                            StreamId :: binary(),
                            Version :: non_neg_integer()) ->
    ok | {error, term()}.

%% List all snapshot versions for a stream.
-callback list_versions(StoreId :: atom(), StreamId :: binary()) ->
    {ok, [non_neg_integer()]} | {error, term()}.
