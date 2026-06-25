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

-include_lib("evoq/include/evoq_types.hrl").

%% API
-export([append/4, read/5, version/2, exists/2, has_events/1]).
-export([list_streams/1, read_all/3, read_all/4]).
-export([read_all_events/2, read_events_by_types/3]).
-export([read_all_global/3]).
-export([read_by_tags/4, read_by_metadata/3, append_if_no_tag_matches/4]).
-export([ccc_read_by_payload/4, ccc_read_by_payload_hash/4]).
-export([payload_indexes/1, payload_hash_indexes/1]).

%% Event conversion
-export([event_to_map/1]).

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

%% @doc Read events across streams by tag match.
%% Match is the atom any (union) or all (intersection).
-spec read_by_tags(atom(), [binary()], any | all, pos_integer()) ->
    {ok, [map()]} | {error, term()}.
read_by_tags(StoreId, Tags, Match, BatchSize) ->
    Adapter = get_adapter(),
    case Adapter:read_by_tags(StoreId, Tags, Match, BatchSize) of
        {ok, Events} -> {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error -> Error
    end.

%% @doc Read events across streams whose metadata Key equals Value.
%% The cross-cutting lineage primitive (causation_id / correlation_id /
%% conversation_id). Backed by reckon-db's {meta, Key} index when declared.
-spec read_by_metadata(atom(), binary(), binary()) ->
    {ok, [map()]} | {error, term()}.
read_by_metadata(StoreId, Key, Value) ->
    Adapter = get_adapter(),
    case Adapter:read_by_metadata(StoreId, Key, Value) of
        {ok, Events} -> {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error -> Error
    end.

%% @doc Conditionally append events under the DCB pseudo-stream
%% (Dynamic Consistency Boundary, paired with reckon-db 3.1.0+).
%%
%% TagFilter is the consistency context query (a backend-defined
%% tag-filter term). SeqCutoff is the highest seq the caller saw
%% (or -1 for "saw nothing"). Returns {error, {context_changed, MaxSeq}}
%% if any event matching TagFilter has seq above SeqCutoff.
%%
%% The typical caller is evoq_decision_runtime; user code uses the
%% evoq_decision behaviour rather than calling this directly.
-spec append_if_no_tag_matches(atom(), term(), integer(), [map()]) ->
      {ok, non_neg_integer()}
    | {error, {context_changed, non_neg_integer()}}
    | {error, term()}.
append_if_no_tag_matches(StoreId, TagFilter, SeqCutoff, Events) ->
    Adapter = get_adapter(),
    Adapter:append_if_no_tag_matches(StoreId, TagFilter, SeqCutoff, Events).

%% @doc Read DCB events whose payload field Key equals Value (CCC).
%%
%% Backed by reckon-db's {payload, Key} index, evaluated server-side.
%% The consistency-boundary read counterpart to the payload condition
%% that append_if_no_tag_matches/4 already evaluates atomically at
%% append. Requires the store to declare the {payload, Key} index;
%% an undeclared index surfaces as a backend error here, which the
%% decision runtime maps to {payload_index_unavailable, Filter}.
-spec ccc_read_by_payload(atom(), binary(), binary(), pos_integer()) ->
    {ok, [map()]} | {error, term()}.
ccc_read_by_payload(StoreId, Key, Value, BatchSize) ->
    Adapter = get_adapter(),
    case Adapter:ccc_read_by_payload(StoreId, Key, Value, BatchSize) of
        {ok, Events} -> {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error -> Error
    end.

%% @doc Read DCB events matching a composite payload field combination (CCC).
%%
%% Backed by reckon-db's {payload_hash, Keys} index. All Keys must
%% match their corresponding Values; field order is ignored.
-spec ccc_read_by_payload_hash(atom(), [binary()], [binary()], pos_integer()) ->
    {ok, [map()]} | {error, term()}.
ccc_read_by_payload_hash(StoreId, Keys, Values, BatchSize) ->
    Adapter = get_adapter(),
    case Adapter:ccc_read_by_payload_hash(StoreId, Keys, Values, BatchSize) of
        {ok, Events} -> {ok, [event_to_map(E) || E <- Events]};
        {error, _} = Error -> Error
    end.

%% @doc Payload field keys individually indexed in a store ({payload, Key}).
%%
%% Used by the decision runtime to fail early when a payload filter
%% references an undeclared index. Returns {ok, [Key]}.
-spec payload_indexes(atom()) -> {ok, [binary()]} | {error, term()}.
payload_indexes(StoreId) ->
    Adapter = get_adapter(),
    case erlang:function_exported(Adapter, payload_indexes, 1) of
        true -> Adapter:payload_indexes(StoreId);
        false -> {error, introspection_unavailable}
    end.

%% @doc Payload field key-sets hash-indexed in a store ({payload_hash, Keys}).
-spec payload_hash_indexes(atom()) -> {ok, [[binary()]]} | {error, term()}.
payload_hash_indexes(StoreId) ->
    Adapter = get_adapter(),
    case erlang:function_exported(Adapter, payload_hash_indexes, 1) of
        true -> Adapter:payload_hash_indexes(StoreId);
        false -> {error, introspection_unavailable}
    end.

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

%% @doc Check if a store contains at least one event.
-spec has_events(atom()) -> boolean().
has_events(StoreId) ->
    Adapter = get_adapter(),
    has_events(erlang:function_exported(Adapter, has_events, 1), Adapter, StoreId).

has_events(true, Adapter, StoreId) ->
    Adapter:has_events(StoreId);
has_events(false, _Adapter, StoreId) ->
    has_any_event(read_all_global(StoreId, 0, 1)).

has_any_event({ok, [_ | _]}) -> true;
has_any_event(_) -> false.

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
    read_all_events(list_streams(StoreId), StoreId, BatchSize).

read_all_events({ok, StreamIds}, StoreId, BatchSize) ->
    AllEvents = lists:flatmap(fun(Sid) -> stream_events(StoreId, BatchSize, Sid) end,
                             StreamIds),
    %% Sort by global position if available, or version
    {ok, lists:sort(fun by_global_position/2, AllEvents)};
read_all_events({error, Reason}, _StoreId, _BatchSize) ->
    {error, Reason}.

%% @private Read one stream's events, tagging each with its stream_id.
stream_events(StoreId, BatchSize, StreamId) ->
    tag_stream(read_all(StoreId, StreamId, BatchSize, forward), StreamId).

tag_stream({ok, Events}, StreamId) ->
    [E#{stream_id => StreamId} || E <- Events];
tag_stream({error, _}, _StreamId) ->
    [].

by_global_position(E1, E2) ->
    global_pos(E1) =< global_pos(E2).

global_pos(E) ->
    maps:get(global_position, E, maps:get(version, E, 0)).

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

%% @doc Read all events across all streams in global order.
%%
%% Returns events sorted by epoch_us, starting from Offset.
%% Used for catch-up subscriptions and global event replay.
%% Falls back to read_all_events/2 if adapter does not implement
%% the optional read_all_global/3 callback.
-spec read_all_global(atom(), non_neg_integer(), pos_integer()) ->
    {ok, [evoq_event()]} | {error, term()}.
read_all_global(StoreId, Offset, BatchSize) ->
    Adapter = get_adapter(),
    case erlang:function_exported(Adapter, read_all_global, 3) of
        true ->
            Adapter:read_all_global(StoreId, Offset, BatchSize);
        false ->
            read_all_events(StoreId, BatchSize)
    end.

%%====================================================================
%% Internal Functions
%%====================================================================

%% @private Convert event record to a flat map.
%%
%% Business event fields (stored in the `data` field by reckon_db) are
%% merged into the top level so that aggregate apply/2 callbacks always
%% see the same shape regardless of whether the event came from execute
%% (flat map) or from a store replay (envelope with nested data).
%%
%% Envelope fields (event_id, version, metadata, etc.) are preserved
%% at the top level.  If a data field collides with an envelope field
%% the envelope value wins (atom keys take precedence).
%% @private Resolve event_type: prefer the record field, fall back to the
%% value inside data (atom key first, then binary) when it's undefined.
coalesce_event_type(undefined, Data) when is_map(Data) ->
    event_type_from_data(maps:find(event_type, Data), Data);
coalesce_event_type(undefined, _Data) ->
    undefined;
coalesce_event_type(Type, _Data) ->
    Type.

event_type_from_data({ok, T}, _Data) -> T;
event_type_from_data(error, Data) -> maps:get(<<"event_type">>, Data, undefined).

-spec event_to_map(evoq_event() | map()) -> map().
event_to_map(#evoq_event{} = Event) ->
    %% Resolve event_type: prefer the record field, but fall back to the
    %% value inside data when the record field is undefined (happens when
    %% the event was stored with binary keys that the adapter didn't extract).
    EventType = coalesce_event_type(Event#evoq_event.event_type, Event#evoq_event.data),
    Envelope = #{
        event_id => Event#evoq_event.event_id,
        event_type => EventType,
        stream_id => Event#evoq_event.stream_id,
        version => Event#evoq_event.version,
        metadata => Event#evoq_event.metadata,
        timestamp => Event#evoq_event.timestamp,
        epoch_us => Event#evoq_event.epoch_us,
        data_content_type => Event#evoq_event.data_content_type,
        metadata_content_type => Event#evoq_event.metadata_content_type,
        %% Chain hash of the predecessor — preserved through the
        %% adapter boundary for keyless defense-in-depth chain
        %% checks by projections / process managers. `undefined`
        %% for legacy events (pre-2.1 reckon-db).
        prev_event_hash => Event#evoq_event.prev_event_hash
    },
    %% Flatten: merge business data into top level, envelope wins on collision
    case Event#evoq_event.data of
        Data when is_map(Data) -> maps:merge(Data, Envelope);
        _ -> Envelope
    end;
event_to_map(EventMap) when is_map(EventMap) ->
    EventMap.
