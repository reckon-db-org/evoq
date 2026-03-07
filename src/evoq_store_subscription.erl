%% @doc Bridge between event stores and evoq routing infrastructure.
%%
%% Creates per-event-type subscriptions to a reckon-db store,
%% matching evoq's event-type-oriented architecture. Only events
%% that have registered handlers/projections/PMs are subscribed to.
%%
%% This is the critical link that connects the event store to evoq
%% behaviours (`evoq_event_handler', `evoq_projection',
%% `evoq_process_manager'). Without it, the routing infrastructure
%% exists but receives no events.
%%
%% == How It Differs from Commanded ==
%%
%% Commanded subscribes to ALL events (stream-oriented) and filters
%% at the handler level. Evoq subscribes per event type at the store
%% level — only relevant events are delivered. This scales better
%% because the store does the filtering, not the application.
%%
%% == Usage ==
%%
%% Start one instance per event store:
%%
%% ```
%% %% In your application supervisor or startup:
%% evoq_store_subscription:start_link(plugins_store)
%% evoq_store_subscription:start_link(settings_store, #{})
%% '''
%%
%% All modules implementing evoq behaviours that have registered with
%% `evoq_event_type_registry' will automatically receive matching events.
%%
%% == Dynamic Registration ==
%%
%% When a handler registers interest in a new event type AFTER the
%% store subscription has started, the type registry notifies this
%% module via `{new_event_type, EventType}' messages. A new per-type
%% subscription is created automatically.
%%
%% @author rgfaber
-module(evoq_store_subscription).
-behaviour(gen_server).

-include("evoq_types.hrl").

%% API
-export([start_link/1, start_link/2]).

%% Internal (exported for testing)
-export([evoq_event_to_routable/1, route_event/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    store_id :: atom(),
    %% Map of event_type => subscription_id
    subscriptions = #{} :: #{binary() => binary()},
    opts :: map()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a store subscription with default options.
-spec start_link(atom()) -> {ok, pid()} | {error, term()}.
start_link(StoreId) ->
    start_link(StoreId, #{}).

%% @doc Start a store subscription with options.
%%
%% Options:
%%   start_from - Starting position (default: 0)
-spec start_link(atom(), map()) -> {ok, pid()} | {error, term()}.
start_link(StoreId, Opts) ->
    Name = registration_name(StoreId),
    gen_server:start_link({local, Name}, ?MODULE, {StoreId, Opts}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({StoreId, Opts}) ->
    %% Register as a listener with the type registry.
    %% This atomically returns all currently registered event types
    %% AND subscribes us for future type registration notifications.
    {ok, CurrentTypes} = evoq_event_type_registry:register_listener(self()),

    %% Create per-event-type subscriptions for all current types
    Subs = lists:foldl(fun(EventType, Acc) ->
        case subscribe_to_type(StoreId, EventType, Opts) of
            {ok, SubId} ->
                Acc#{EventType => SubId};
            {error, Reason} ->
                logger:warning("[evoq] Failed to subscribe to ~s/~s: ~p",
                               [StoreId, EventType, Reason]),
                Acc
        end
    end, #{}, CurrentTypes),

    logger:info("[evoq] Store subscription started for ~s (~b event types)",
                [StoreId, map_size(Subs)]),

    {ok, #state{
        store_id = StoreId,
        subscriptions = Subs,
        opts = Opts
    }}.

%% @private
handle_info({new_event_type, EventType}, #state{
    store_id = StoreId,
    subscriptions = Subs,
    opts = Opts
} = State) ->
    %% A new event type was registered in the type registry.
    %% Create a subscription if we don't have one yet.
    case maps:is_key(EventType, Subs) of
        true ->
            {noreply, State};
        false ->
            case subscribe_to_type(StoreId, EventType, Opts) of
                {ok, SubId} ->
                    logger:info("[evoq] New subscription for ~s/~s",
                                [StoreId, EventType]),
                    {noreply, State#state{
                        subscriptions = Subs#{EventType => SubId}
                    }};
                {error, Reason} ->
                    logger:warning("[evoq] Failed to subscribe to ~s/~s: ~p",
                                   [StoreId, EventType, Reason]),
                    {noreply, State}
            end
    end;

handle_info({events, Events}, State) when is_list(Events) ->
    lists:foreach(fun route_event/1, Events),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% @private
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{store_id = StoreId}) ->
    evoq_event_type_registry:unregister_listener(self()),
    logger:info("[evoq] Store subscription stopping for ~s", [StoreId]),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Subscribe to a single event type on the store.
-spec subscribe_to_type(atom(), binary(), map()) -> {ok, binary()} | {error, term()}.
subscribe_to_type(StoreId, EventType, Opts) ->
    SubName = subscription_name(StoreId, EventType),
    StartFrom = maps:get(start_from, Opts, 0),
    evoq_subscriptions:subscribe(
        StoreId, event_type, EventType, SubName,
        #{subscriber_pid => self(), start_from => StartFrom}
    ).

%% @private Route a single evoq event to both event router and PM router.
-spec route_event(evoq_event() | term()) -> ok.
route_event(#evoq_event{} = E) ->
    {Event, Metadata} = evoq_event_to_routable(E),
    evoq_event_router:route_event(Event, Metadata),
    evoq_pm_router:route_event(Event, Metadata),
    ok;
route_event(_Other) ->
    ok.

%% @private Convert an #evoq_event{} record to the map format
%% expected by evoq_event_router and evoq_pm_router.
%%
%% The Event map contains the full event envelope (including data).
%% The Metadata map contains routing metadata for handlers.
-spec evoq_event_to_routable(evoq_event()) -> {map(), map()}.
evoq_event_to_routable(#evoq_event{
    event_id = EventId,
    event_type = EventType,
    stream_id = StreamId,
    version = Version,
    data = Data,
    metadata = EventMetadata,
    tags = Tags,
    timestamp = Timestamp,
    epoch_us = EpochUs
}) ->
    Event = #{
        event_type => EventType,
        event_id => EventId,
        stream_id => StreamId,
        version => Version,
        data => Data,
        tags => Tags,
        timestamp => Timestamp,
        epoch_us => EpochUs
    },
    Metadata = EventMetadata#{
        event_id => EventId,
        stream_id => StreamId,
        version => Version
    },
    {Event, Metadata}.

%% @private Generate a unique registration name for this store subscription.
-spec registration_name(atom()) -> atom().
registration_name(StoreId) ->
    list_to_atom("evoq_store_sub_" ++ atom_to_list(StoreId)).

%% @private Generate a subscription name for a specific event type.
-spec subscription_name(atom(), binary()) -> binary().
subscription_name(StoreId, EventType) ->
    iolist_to_binary([
        <<"evoq_router_">>,
        atom_to_binary(StoreId, utf8),
        <<"_">>,
        EventType
    ]).
