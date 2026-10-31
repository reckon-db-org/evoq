%% @doc Store-level introspection via adapter.
%%
%% Provides aggregate queries for debugging and monitoring.
%% Delegates to the configured event store adapter.
%%
%% @author rgfaber
-module(evoq_store_inspector).

-export([
    store_stats/1,
    list_all_snapshots/1,
    list_subscriptions/1,
    subscription_lag/2,
    event_type_summary/1,
    stream_info/2
]).

%% @doc Aggregate statistics for a store.
-spec store_stats(atom()) -> {ok, map()} | {error, term()}.
store_stats(StoreId) ->
    call_adapter(store_stats, [StoreId]).

%% @doc List all snapshots across all streams.
-spec list_all_snapshots(atom()) -> {ok, [map()]} | {error, term()}.
list_all_snapshots(StoreId) ->
    call_adapter(list_all_snapshots, [StoreId]).

%% @doc List all subscriptions with checkpoint positions.
-spec list_subscriptions(atom()) -> {ok, [map()]} | {error, term()}.
list_subscriptions(StoreId) ->
    call_adapter(list_subscriptions, [StoreId]).

%% @doc Calculate lag for a specific subscription.
-spec subscription_lag(atom(), binary()) -> {ok, map()} | {error, term()}.
subscription_lag(StoreId, SubscriptionName) ->
    call_adapter(subscription_lag, [StoreId, SubscriptionName]).

%% @doc Census of event types in the store.
-spec event_type_summary(atom()) -> {ok, [map()]} | {error, term()}.
event_type_summary(StoreId) ->
    call_adapter(event_type_summary, [StoreId]).

%% @doc Detailed info for a single stream.
-spec stream_info(atom(), binary()) -> {ok, map()} | {error, term()}.
stream_info(StoreId, StreamId) ->
    call_adapter(stream_info, [StoreId, StreamId]).

%%====================================================================
%% Internal
%%====================================================================

call_adapter(Fun, Args) ->
    Adapter = evoq_event_store:get_adapter(),
    %% Loaded first (evoq#39): function_exported/3 answers false for a module
    %% that is not loaded yet, and this answers `{not_supported, Fun}' when it
    %% is false -- so an inspection run on a cold node told the operator the
    %% store does not support a call it does.
    _ = code:ensure_loaded(Adapter),
    case erlang:function_exported(Adapter, Fun, length(Args)) of
        true -> erlang:apply(Adapter, Fun, Args);
        false -> {error, {not_supported, Fun}}
    end.
