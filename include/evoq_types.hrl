%% @doc Core type definitions for evoq CQRS/Event Sourcing framework
%%
%% Contains record definitions used throughout evoq for events,
%% snapshots, and subscriptions. These are abstract types that
%% adapters translate to their backend-specific representations.
%%
%% @author rgfaber

-ifndef(EVOQ_TYPES_HRL).
-define(EVOQ_TYPES_HRL, true).

%%====================================================================
%% Version Constants
%% (guarded to avoid redefinition when used with esdb_gater_types.hrl)
%%====================================================================

%% NO_STREAM: Stream must not exist (first write)
-ifndef(NO_STREAM).
-define(NO_STREAM, -1).
-endif.

%% ANY_VERSION: No version check, always append
-ifndef(ANY_VERSION).
-define(ANY_VERSION, -2).
-endif.

%% STREAM_EXISTS: Stream must exist
-ifndef(STREAM_EXISTS).
-define(STREAM_EXISTS, -4).
-endif.

%%====================================================================
%% Content Types
%% (guarded to avoid redefinition when used with esdb_gater_types.hrl)
%%====================================================================

-ifndef(CONTENT_TYPE_JSON).
-define(CONTENT_TYPE_JSON, <<"application/json">>).
-endif.

-ifndef(CONTENT_TYPE_BINARY).
-define(CONTENT_TYPE_BINARY, <<"application/octet-stream">>).
-endif.

%%====================================================================
%% Event Record
%%====================================================================

-record(evoq_event, {
    %% Unique identifier for this event
    event_id :: binary(),

    %% Type of event (e.g., <<"user_created">>)
    event_type :: binary(),

    %% Stream this event belongs to
    stream_id :: binary(),

    %% Version/position within the stream (0-based)
    version :: non_neg_integer(),

    %% Event payload (typically a map)
    data :: map() | binary(),

    %% Event metadata (correlation_id, causation_id, etc.)
    metadata :: map(),

    %% Tags for cross-stream querying (optional)
    %% Example: [<<"student:456">>, <<"course:CS101">>]
    %% Tags are used for QUERY purposes only, NOT for concurrency control.
    tags :: [binary()] | undefined,

    %% Timestamp when event was created
    timestamp :: integer(),

    %% Microsecond epoch timestamp for ordering
    epoch_us :: integer(),

    %% Content type of data field
    data_content_type = ?CONTENT_TYPE_JSON :: binary(),

    %% Content type of metadata field
    metadata_content_type = ?CONTENT_TYPE_JSON :: binary()
}).

-type evoq_event() :: #evoq_event{}.

%%====================================================================
%% Tag Match Mode
%%====================================================================

%% How to match multiple tags:
%%   any - Return events matching ANY of the tags (union)
%%   all - Return events matching ALL of the tags (intersection)
-type evoq_tag_match() :: any | all.

%%====================================================================
%% Subscription Types
%%====================================================================

-type evoq_subscription_type() :: stream | event_type | event_pattern | event_payload | tags.

%%====================================================================
%% Subscription Record
%%====================================================================

-record(evoq_subscription, {
    %% Unique identifier for this subscription
    id :: binary(),

    %% Type of subscription (stream, event_type, event_pattern, event_payload)
    type :: evoq_subscription_type(),

    %% Selector for matching events (stream_id, event_type, pattern map, etc.)
    selector :: binary() | map(),

    %% Human-readable name for this subscription
    subscription_name :: binary(),

    %% PID of the subscriber process (for non-persistent)
    subscriber_pid :: pid() | undefined,

    %% When the subscription was created
    created_at :: integer(),

    %% Size of the emitter pool for this subscription
    pool_size = 1 :: pos_integer(),

    %% Current checkpoint position
    checkpoint :: non_neg_integer() | undefined,

    %% Additional options
    options :: map()
}).

-type evoq_subscription() :: #evoq_subscription{}.

%%====================================================================
%% Snapshot Record
%%====================================================================

-record(evoq_snapshot, {
    %% Stream this snapshot belongs to
    stream_id :: binary(),

    %% Version at which snapshot was taken
    version :: non_neg_integer(),

    %% Snapshot payload (aggregate state)
    data :: map() | binary(),

    %% Snapshot metadata
    metadata :: map(),

    %% When snapshot was created
    timestamp :: integer()
}).

-type evoq_snapshot() :: #evoq_snapshot{}.

%%====================================================================
%% Read Direction
%%====================================================================

-type evoq_read_direction() :: forward | backward.

%%====================================================================
%% Append Result
%%====================================================================

-record(evoq_append_result, {
    %% New stream version after append
    version :: non_neg_integer(),

    %% Global position (if applicable)
    position :: non_neg_integer() | undefined,

    %% Number of events appended
    count :: non_neg_integer()
}).

-type evoq_append_result() :: #evoq_append_result{}.

%%====================================================================
%% Error Types
%%====================================================================

-type evoq_append_error() ::
    {wrong_expected_version, ExpectedVersion :: integer(), ActualVersion :: integer()} |
    {stream_deleted, StreamId :: binary()} |
    {timeout, Reason :: term()} |
    {error, Reason :: term()}.

-type evoq_read_error() ::
    {stream_not_found, StreamId :: binary()} |
    {timeout, Reason :: term()} |
    {error, Reason :: term()}.

-endif. %% EVOQ_TYPES_HRL
