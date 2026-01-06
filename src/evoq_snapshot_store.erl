%% @doc Wrapper for snapshot operations via adapter.
%%
%% Provides a consistent interface for snapshot operations,
%% delegating to a configured adapter.
%%
%% == Configuration (Required) ==
%%
%% You must configure an adapter in your application config:
%%
%% ```
%% {evoq, [
%%     {snapshot_store_adapter, evoq_esdb_gater_adapter}
%% ]}
%% '''
%%
%% @author rgfaber
-module(evoq_snapshot_store).

-include_lib("evoq/include/evoq_types.hrl").

%% API
-export([save/5, load/2, load/3, delete/2, delete/3]).

%% Configuration
-export([get_adapter/0, set_adapter/1]).

%%====================================================================
%% Configuration
%%====================================================================

%% @doc Get the configured snapshot store adapter.
%% Crashes if no adapter is configured.
-spec get_adapter() -> module().
get_adapter() ->
    case application:get_env(evoq, snapshot_store_adapter) of
        {ok, Adapter} -> Adapter;
        undefined -> error({not_configured, snapshot_store_adapter})
    end.

%% @doc Set the snapshot store adapter (primarily for testing).
-spec set_adapter(module()) -> ok.
set_adapter(Adapter) ->
    application:set_env(evoq, snapshot_store_adapter, Adapter).

%%====================================================================
%% API
%%====================================================================

%% @doc Save a snapshot.
-spec save(atom(), binary(), non_neg_integer(), term(), map()) -> ok | {error, term()}.
save(StoreId, StreamId, Version, Data, Metadata) ->
    Adapter = get_adapter(),
    Adapter:save(StoreId, StreamId, Version, Data, Metadata).

%% @doc Load the latest snapshot for a stream.
-spec load(atom(), binary()) -> {ok, map()} | {error, not_found | term()}.
load(StoreId, StreamId) ->
    Adapter = get_adapter(),
    case Adapter:read(StoreId, StreamId) of
        {ok, #evoq_snapshot{} = Snapshot} ->
            {ok, snapshot_to_map(Snapshot)};
        {ok, SnapshotMap} when is_map(SnapshotMap) ->
            {ok, SnapshotMap};
        {error, _} = Error ->
            Error
    end.

%% @doc Load a snapshot at a specific version.
-spec load(atom(), binary(), non_neg_integer()) -> {ok, map()} | {error, not_found | term()}.
load(StoreId, StreamId, Version) ->
    Adapter = get_adapter(),
    case Adapter:read_at_version(StoreId, StreamId, Version) of
        {ok, #evoq_snapshot{} = Snapshot} ->
            {ok, snapshot_to_map(Snapshot)};
        {ok, SnapshotMap} when is_map(SnapshotMap) ->
            {ok, SnapshotMap};
        {error, _} = Error ->
            Error
    end.

%% @doc Delete all snapshots for a stream.
-spec delete(atom(), binary()) -> ok | {error, term()}.
delete(StoreId, StreamId) ->
    Adapter = get_adapter(),
    Adapter:delete(StoreId, StreamId).

%% @doc Delete a snapshot at a specific version.
-spec delete(atom(), binary(), non_neg_integer()) -> ok | {error, term()}.
delete(StoreId, StreamId, Version) ->
    Adapter = get_adapter(),
    Adapter:delete_at_version(StoreId, StreamId, Version).

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Convert snapshot record to map
-spec snapshot_to_map(evoq_snapshot()) -> map().
snapshot_to_map(#evoq_snapshot{} = Snapshot) ->
    #{
        stream_id => Snapshot#evoq_snapshot.stream_id,
        version => Snapshot#evoq_snapshot.version,
        data => Snapshot#evoq_snapshot.data,
        metadata => Snapshot#evoq_snapshot.metadata,
        timestamp => Snapshot#evoq_snapshot.timestamp
    }.
