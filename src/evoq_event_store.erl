%% @doc Wrapper for event store operations via adapter.
%%
%% Provides a consistent interface for event store operations,
%% delegating to a configured adapter.
%%
%% == Configuration (Required) ==
%%
%% You must configure an adapter in your application config:
%%
%% ```
%% {evoq, [
%%     {event_store_adapter, evoq_esdb_gater_adapter}
%% ]}
%% '''
%%
%% Available adapters:
%% - evoq_esdb_gater_adapter (from reckon_evoq package)
%%
%% @author rgfaber
-module(evoq_event_store).

-include_lib("reckon_gater/include/esdb_gater_types.hrl").

%% API
-export([append/4, read/5, version/2, exists/2]).
-export([list_streams/1, read_all/3, read_all/4]).
-export([read_all_events/2, read_events_by_types/3]).

%% Configuration
-export([get_adapter/0, set_adapter/1]).

%%====================================================================
%% Configuration
%%====================================================================

%% @doc Get the configured event store adapter.
%% Crashes if no adapter is configured.
-spec get_adapter() -> module().
get_adapter() ->
    case application:get_env(evoq, event_store_adapter) of
        {ok, Adapter} -> Adapter;
        undefined -> error({not_configured, event_store_adapter})
    end.

%% @doc Set the event store adapter (primarily for testing).
-spec set_adapter(module()) -> ok.
set_adapter(Adapter) ->
    application:set_env(evoq, event_store_adapter, Adapter).

%%====================================================================
%% API
%%====================================================================

%% @doc Append events to a stream.
-spec append(atom(), binary(), integer(), [map()]) ->
    {ok, non_neg_integer()} | {error, term()}.
append(StoreId, StreamId, ExpectedVersion, Events) ->
    Adapter = get_adapter(),
    Adapter:append(StoreId, StreamId, ExpectedVersion, Events).

%% @doc Read events from a stream.
-spec read(atom(), binary(), non_neg_integer(), pos_integer(), forward | backward) ->
    {ok, [map()]} | {error, term()}.
read(StoreId, StreamId, FromVersion, Count, Direction) ->
    Adapter = get_adapter(),
    case Adapter:read(StoreId, StreamId, FromVersion, Count, Direction) of
        {ok, Events} ->
            %% Convert to maps if needed
            {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error ->
            Error
    end.

%% @doc Get the current version of a stream.
-spec version(atom(), binary()) -> integer().
version(StoreId, StreamId) ->
    Adapter = get_adapter(),
    Adapter:version(StoreId, StreamId).

%% @doc Check if a stream exists.
-spec exists(atom(), binary()) -> boolean().
exists(StoreId, StreamId) ->
    Adapter = get_adapter(),
    Adapter:exists(StoreId, StreamId).

%% @doc List all streams in the store.
-spec list_streams(atom()) -> {ok, [binary()]} | {error, term()}.
list_streams(StoreId) ->
    Adapter = get_adapter(),
    Adapter:list_streams(StoreId).

%% @doc Read all events from a stream.
-spec read_all(atom(), binary(), forward | backward) -> {ok, [map()]} | {error, term()}.
read_all(StoreId, StreamId, Direction) ->
    read_all(StoreId, StreamId, 1000, Direction).

%% @doc Read all events from a stream with batch size.
-spec read_all(atom(), binary(), pos_integer(), forward | backward) -> {ok, [map()]} | {error, term()}.
read_all(StoreId, StreamId, _BatchSize, Direction) ->
    Adapter = get_adapter(),
    case Adapter:read_all(StoreId, StreamId, Direction) of
        {ok, Events} ->
            %% Convert to maps if needed
            {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error ->
            Error
    end.

%% @doc Read all events from all streams, sorted by global position.
%% This is useful for projection rebuild.
-spec read_all_events(atom(), pos_integer()) -> {ok, [map()]} | {error, term()}.
read_all_events(StoreId, BatchSize) ->
    case list_streams(StoreId) of
        {ok, StreamIds} ->
            AllEvents = lists:flatmap(fun(StreamId) ->
                case read_all(StoreId, StreamId, BatchSize, forward) of
                    {ok, Events} ->
                        %% Add stream_id to metadata for each event
                        [E#{stream_id => StreamId} || E <- Events];
                    {error, _} ->
                        []
                end
            end, StreamIds),
            %% Sort by global position if available, or version
            SortedEvents = lists:sort(fun(E1, E2) ->
                P1 = maps:get(global_position, E1, maps:get(version, E1, 0)),
                P2 = maps:get(global_position, E2, maps:get(version, E2, 0)),
                P1 =< P2
            end, AllEvents),
            {ok, SortedEvents};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Read all events of specific types from all streams.
%%
%% Routes through the adapter which uses native filtering when available.
%% Returns events sorted by epoch_us (global ordering).
-spec read_events_by_types(atom(), [binary()], pos_integer()) -> {ok, [map()]} | {error, term()}.
read_events_by_types(StoreId, EventTypes, BatchSize) ->
    Adapter = get_adapter(),
    case Adapter:read_by_event_types(StoreId, EventTypes, BatchSize) of
        {ok, Events} ->
            %% Convert event records to maps for evoq compatibility
            EventMaps = [event_to_map(E) || E <- Events],
            {ok, EventMaps};
        {error, _} = Error ->
            Error
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Convert event record to map
-spec event_to_map(event() | map()) -> map().
event_to_map(#event{} = Event) ->
    #{
        event_id => Event#event.event_id,
        event_type => Event#event.event_type,
        stream_id => Event#event.stream_id,
        version => Event#event.version,
        data => Event#event.data,
        metadata => Event#event.metadata,
        timestamp => Event#event.timestamp,
        epoch_us => Event#event.epoch_us,
        data_content_type => Event#event.data_content_type,
        metadata_content_type => Event#event.metadata_content_type
    };
event_to_map(EventMap) when is_map(EventMap) ->
    EventMap.
