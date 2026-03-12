%% @doc Bridge between event stores and evoq routing infrastructure.
%%
%% Creates a single $all subscription to a reckon-db store, receiving
%% ALL events in global store order. Events are filtered locally by
%% checking against registered event types in the type registry.
%%
%% This preserves causal ordering across event types within a store,
%% which is critical when projections for related events must execute
%% in the order they were appended (e.g., license_initiated before
%% license_published).
%%
%% == How It Works ==
%%
%% 1. Replays all historical events from the store (catch-up phase)
%% 2. Subscribes to the store's $all stream (by_stream, selector $all)
%% 3. Receives ALL new events in store-global order
%% 4. For each event, checks if any handler is registered for its type
%% 5. Routes matching events to evoq_event_router and evoq_pm_router
%% 6. Skips events with no registered handlers (zero cost)
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
%% @author rgfaber
-module(evoq_store_subscription).
-behaviour(gen_server).

-include("evoq_types.hrl").

%% API
-export([start_link/1, start_link/2]).

%% Internal (exported for testing)
-export([evoq_event_to_routable/1, route_event/1, route_events_with_seq/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    store_id :: atom(),
    subscription_id :: binary() | undefined,
    opts :: map(),
    %% Monotonically increasing sequence number for events delivered
    %% through this subscription. Used instead of stream-local version
    %% in metadata so that projections receiving events from $all
    %% subscriptions (multiple streams) have a valid checkpoint.
    seq :: non_neg_integer()
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
    %% We still register so we know about new types, but we no longer
    %% need to create per-type subscriptions — we subscribe to $all.
    {ok, _CurrentTypes} = evoq_event_type_registry:register_listener(self()),

    %% Phase 1: Replay historical events (catch-up).
    %% This populates projections with all events stored before this
    %% subscription was created. Events are routed through the same
    %% path as live events, maintaining causal order.
    Seq0 = catch_up_historical(StoreId),

    %% Phase 2: Subscribe to new events going forward.
    %% The $all subscription will only deliver events appended AFTER
    %% the subscription is created (Khepri triggers are prospective).
    SubId = case subscribe_to_all(StoreId, Opts) of
        {ok, Id} ->
            Id;
        {error, Reason} ->
            logger:warning("[evoq] Failed to subscribe to $all for ~s: ~p",
                           [StoreId, Reason]),
            undefined
    end,

    logger:info("[evoq] Store subscription started for ~s (catch-up: ~b events replayed)",
                [StoreId, Seq0]),

    {ok, #state{
        store_id = StoreId,
        subscription_id = SubId,
        opts = Opts,
        seq = Seq0
    }}.

%% @private
%% New event types are registered dynamically. Since we subscribe to
%% $all, we don't need to create new subscriptions — events for this
%% type are already being delivered. We just acknowledge and move on.
handle_info({new_event_type, EventType}, #state{store_id = StoreId} = State) ->
    logger:info("[evoq] New event type registered for ~s: ~s (already covered by $all)",
                [StoreId, EventType]),
    {noreply, State};

handle_info({events, Events}, #state{seq = Seq0} = State) when is_list(Events) ->
    Seq1 = route_events_with_seq(Events, Seq0),
    {noreply, State#state{seq = Seq1}};

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

%% @private Replay all historical events from the store.
%% Reads events in batches via read_all_global and routes each batch
%% through the same routing path as live events.
%% Returns the final sequence number (= total events replayed).
-spec catch_up_historical(atom()) -> non_neg_integer().
catch_up_historical(StoreId) ->
    BatchSize = 1000,
    catch_up_loop(StoreId, 0, BatchSize, 0).

-spec catch_up_loop(atom(), non_neg_integer(), pos_integer(), non_neg_integer()) ->
    non_neg_integer().
catch_up_loop(StoreId, Offset, BatchSize, Seq) ->
    case evoq_event_store:read_all_global(StoreId, Offset, BatchSize) of
        {ok, []} ->
            logger:info("[evoq] Catch-up ~s: read_all_global returned 0 events at offset ~b",
                        [StoreId, Offset]),
            Seq;
        {ok, Events} ->
            %% Log event types and handler status for diagnostics
            lists:foreach(fun(E) ->
                ET = case E of
                    #evoq_event{event_type = T} -> T;
                    _ -> unknown
                end,
                Handlers = evoq_event_type_registry:get_handlers(ET),
                logger:info("[evoq] Catch-up ~s: event_type=~p handlers=~b",
                            [StoreId, ET, length(Handlers)])
            end, Events),
            Seq1 = route_events_with_seq(Events, Seq),
            logger:info("[evoq] Catch-up ~s: routed ~b events (seq ~b -> ~b)",
                        [StoreId, length(Events), Seq, Seq1]),
            case length(Events) < BatchSize of
                true ->
                    Seq1;
                false ->
                    catch_up_loop(StoreId, Offset + length(Events), BatchSize, Seq1)
            end;
        {error, Reason} ->
            logger:warning("[evoq] Catch-up failed for ~s at offset ~b: ~p",
                           [StoreId, Offset, Reason]),
            Seq
    end.

%% @private Subscribe to the $all stream on the store.
%% Uses by_stream subscription type with <<"$all">> selector,
%% which matches events in ALL streams (global store order).
-spec subscribe_to_all(atom(), map()) -> {ok, binary()} | {error, term()}.
subscribe_to_all(StoreId, Opts) ->
    SubName = subscription_name(StoreId),
    StartFrom = maps:get(start_from, Opts, 0),
    evoq_subscriptions:subscribe(
        StoreId, stream, <<"$all">>, SubName,
        #{subscriber_pid => self(), start_from => StartFrom}
    ).

%% @private Route events with a monotonically increasing sequence number.
%% Returns the next sequence number after all events are routed.
-spec route_events_with_seq([evoq_event() | term()], non_neg_integer()) -> non_neg_integer().
route_events_with_seq([], Seq) ->
    Seq;
route_events_with_seq([E | Rest], Seq) ->
    NextSeq = route_event_with_seq(E, Seq),
    route_events_with_seq(Rest, NextSeq).

%% @private Route a single evoq event to both event router and PM router.
%% Only routes events that have registered handlers — others are skipped.
%% The sequence number is injected into metadata as `version' so that
%% projections receiving events from $all subscriptions (multiple streams)
%% see a monotonically increasing checkpoint value instead of stream-local
%% versions that can repeat across streams.
-spec route_event(evoq_event() | term()) -> ok.
route_event(#evoq_event{event_type = EventType} = E) ->
    case evoq_event_type_registry:get_handlers(EventType) of
        [] ->
            ok;
        _Handlers ->
            {Event, Metadata} = evoq_event_to_routable(E),
            evoq_event_router:route_event(Event, Metadata),
            evoq_pm_router:route_event(Event, Metadata),
            ok
    end;
route_event(_Other) ->
    ok.

%% @private Route a single event with sequence-based version override.
-spec route_event_with_seq(evoq_event() | term(), non_neg_integer()) -> non_neg_integer().
route_event_with_seq(#evoq_event{event_type = EventType} = E, Seq) ->
    case evoq_event_type_registry:get_handlers(EventType) of
        [] ->
            Seq;
        _Handlers ->
            {Event, Metadata0} = evoq_event_to_routable(E),
            %% Override version with global sequence so projections
            %% using $all subscriptions get monotonic checkpoints.
            %% Preserve the original stream version as stream_version.
            StreamVersion = maps:get(version, Metadata0, 0),
            Metadata = Metadata0#{version => Seq, stream_version => StreamVersion},
            evoq_event_router:route_event(Event, Metadata),
            evoq_pm_router:route_event(Event, Metadata),
            Seq + 1
    end;
route_event_with_seq(_Other, Seq) ->
    Seq.

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

%% @private Generate a subscription name for the $all subscription.
-spec subscription_name(atom()) -> binary().
subscription_name(StoreId) ->
    iolist_to_binary([
        <<"evoq_all_">>,
        atom_to_binary(StoreId, utf8)
    ]).
