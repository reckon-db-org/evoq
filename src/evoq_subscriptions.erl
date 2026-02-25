%% @doc Facade for subscription operations via adapter.
%%
%% Provides a consistent interface for subscribing to events,
%% delegating to a configured subscription adapter.
%%
%% The adapter is responsible for translating between the event
%% store's native format and evoq's #evoq_event{} records.
%% Subscribers always receive {events, [#evoq_event{}]} messages.
%%
%% == Configuration (Required) ==
%%
%% You must configure a subscription adapter in your application config:
%%
%% ```
%% {evoq, [
%%     {subscription_adapter, reckon_evoq_adapter}
%% ]}
%% '''
%%
%% == Usage ==
%%
%% ```
%% %% Subscribe to events (typically in a gen_server init)
%% {ok, SubId} = evoq_subscriptions:subscribe(
%%     my_store, event_type, <<"order_placed_v1">>,
%%     <<"my_projection">>, #{subscriber_pid => self()}
%% ),
%%
%% %% Receive events in handle_info
%% handle_info({events, Events}, State) ->
%%     lists:foreach(fun(#evoq_event{data = Data}) ->
%%         project(Data)
%%     end, Events),
%%     {noreply, State}.
%% '''
%%
%% @author rgfaber
-module(evoq_subscriptions).

-include_lib("evoq/include/evoq_types.hrl").

%% API
-export([subscribe/5, unsubscribe/2]).
-export([ack/4, get_checkpoint/2]).
-export([list/1, get_by_name/2]).

%% Configuration
-export([get_adapter/0, set_adapter/1]).

%%====================================================================
%% Configuration
%%====================================================================

%% @doc Get the configured subscription adapter.
%% Crashes if no adapter is configured.
-spec get_adapter() -> module().
get_adapter() ->
    case application:get_env(evoq, subscription_adapter) of
        {ok, Adapter} -> Adapter;
        undefined -> error({not_configured, subscription_adapter})
    end.

%% @doc Set the subscription adapter (primarily for testing).
-spec set_adapter(module()) -> ok.
set_adapter(Adapter) ->
    application:set_env(evoq, subscription_adapter, Adapter).

%%====================================================================
%% API
%%====================================================================

%% @doc Subscribe to events from a store.
%%
%% The adapter guarantees that the subscriber_pid receives
%% `{events, [#evoq_event{}]}' messages with proper envelope
%% structure (event_type, stream_id, version, data, metadata).
%%
%% Options:
%%   subscriber_pid - PID to receive events (required for push delivery)
%%   start_from     - Starting position (default: 0)
%%   pool_size      - Number of emitters (default: 1)
-spec subscribe(atom(), evoq_subscription_type(), binary() | map(), binary(), map()) ->
    {ok, binary()} | {error, term()}.
subscribe(StoreId, Type, Selector, SubscriptionName, Opts) ->
    Adapter = get_adapter(),
    Adapter:subscribe(StoreId, Type, Selector, SubscriptionName, Opts).

%% @doc Unsubscribe from events.
-spec unsubscribe(atom(), binary()) -> ok | {error, term()}.
unsubscribe(StoreId, SubscriptionId) ->
    Adapter = get_adapter(),
    Adapter:unsubscribe(StoreId, SubscriptionId).

%% @doc Acknowledge an event has been processed.
%% Updates the subscription checkpoint.
-spec ack(atom(), binary(), binary() | undefined, non_neg_integer()) ->
    ok | {error, term()}.
ack(StoreId, SubscriptionName, StreamId, Position) ->
    Adapter = get_adapter(),
    Adapter:ack(StoreId, SubscriptionName, StreamId, Position).

%% @doc Get the current checkpoint for a subscription.
-spec get_checkpoint(atom(), binary()) ->
    {ok, non_neg_integer()} | {error, not_found | term()}.
get_checkpoint(StoreId, SubscriptionName) ->
    Adapter = get_adapter(),
    Adapter:get_checkpoint(StoreId, SubscriptionName).

%% @doc List all subscriptions for a store.
-spec list(atom()) -> {ok, [evoq_subscription()]} | {error, term()}.
list(StoreId) ->
    Adapter = get_adapter(),
    Adapter:list(StoreId).

%% @doc Get a subscription by name.
-spec get_by_name(atom(), binary()) ->
    {ok, evoq_subscription()} | {error, not_found | term()}.
get_by_name(StoreId, SubscriptionName) ->
    Adapter = get_adapter(),
    Adapter:get_by_name(StoreId, SubscriptionName).
