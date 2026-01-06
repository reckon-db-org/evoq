%% @doc Subscription adapter behavior for evoq
%%
%% Defines the interface for subscription operations. Subscriptions
%% enable event handlers to receive events as they are appended.
%%
%% Supports multiple subscription types:
%% - stream: Subscribe to events from a specific stream
%% - event_type: Subscribe to events of a specific type (across all streams)
%% - event_pattern: Subscribe using wildcard patterns
%% - event_payload: Subscribe based on event payload content
%%
%% @author rgfaber

-module(evoq_subscription_adapter).

-include_lib("evoq/include/evoq_types.hrl").

%%====================================================================
%% Types
%%====================================================================

-type start_from() :: origin | current | {position, non_neg_integer()}.

-export_type([start_from/0]).

%%====================================================================
%% Callback Definitions
%%====================================================================

%% Subscribe to events.
%%
%% Parameters:
%%   StoreId          - The store identifier
%%   Type             - Subscription type (stream, event_type, etc.)
%%   Selector         - What to subscribe to (stream_id, event_type, pattern, etc.)
%%   SubscriptionName - Human-readable name for this subscription
%%   Opts             - Options including:
%%                      - subscriber_pid: PID to receive events
%%                      - start_from: origin | current | {position, N}
%%                      - pool_size: Number of emitters (for load distribution)
-callback subscribe(StoreId :: atom(),
                    Type :: evoq_subscription_type(),
                    Selector :: binary() | map(),
                    SubscriptionName :: binary(),
                    Opts :: map()) ->
    {ok, binary()} | {error, term()}.

%% Unsubscribe from events.
%%
%% Removes the subscription and stops event delivery.
-callback unsubscribe(StoreId :: atom(), SubscriptionId :: binary()) ->
    ok | {error, term()}.

%% Acknowledge an event has been processed.
%%
%% Updates the subscription checkpoint to the acknowledged position.
%% Used for exactly-once delivery semantics.
-callback ack(StoreId :: atom(),
              SubscriptionName :: binary(),
              StreamId :: binary() | undefined,
              Position :: non_neg_integer()) ->
    ok | {error, term()}.

%% Get the current checkpoint for a subscription.
-callback get_checkpoint(StoreId :: atom(), SubscriptionName :: binary()) ->
    {ok, non_neg_integer()} | {error, not_found | term()}.

%% List all subscriptions for a store.
-callback list(StoreId :: atom()) ->
    {ok, [evoq_subscription()]} | {error, term()}.

%% Get a subscription by name.
-callback get_by_name(StoreId :: atom(), SubscriptionName :: binary()) ->
    {ok, evoq_subscription()} | {error, not_found | term()}.
