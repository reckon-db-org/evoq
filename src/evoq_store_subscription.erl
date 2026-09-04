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
-export([evoq_event_to_routable/1, route_event/1, route_events_with_seq/2,
         filter_by_type/2, filter_by_type_set/2]).

%% gen_server callbacks
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {
    store_id :: atom(),
    subscription_id :: binary() | undefined,
    opts :: map(),
    %% Monotonically increasing sequence number for events delivered
    %% through this subscription. Used instead of stream-local version
    %% in metadata so that projections receiving events from $all
    %% subscriptions (multiple streams) have a valid checkpoint.
    seq :: non_neg_integer(),
    %% Event types with a registered handler at the moment this listener
    %% registered (register_listener/1's own snapshot). Gates catch-up
    %% routing -- see handle_continue/2's comment for why a type must NOT
    %% be routed by catch-up just because it gained a handler mid-replay.
    known_types :: [binary()]
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

%% @private Registers with the type registry and returns immediately --
%% see `handle_continue/2' for why catch-up moved out of here.
init({StoreId, Opts}) ->
    %% Register as a listener with the type registry.
    %% We still register so we know about new types, but we no longer
    %% need to create per-type subscriptions — we subscribe to $all.
    %% CurrentTypes is kept (not discarded) -- see handle_continue/2's
    %% comment for why catch-up needs this exact snapshot, not "whatever
    %% has a handler right now".
    {ok, CurrentTypes} = evoq_event_type_registry:register_listener(self()),

    {ok, #state{
        store_id = StoreId,
        subscription_id = undefined,
        opts = Opts,
        seq = 0,
        known_types = CurrentTypes
    }, {continue, catch_up}}.

%% @private Historical replay + the $all subscription, run right after
%% init/1 returns rather than inside it.
%%
%% Catch-up against a store with real accumulated volume is not fast: a
%% full scan-and-sort per page (see reckon_db_streams:read_all_global/3)
%% against a real ~87k-event evidence store measured in the low seconds on
%% capable hardware, and this store's own weaker production hardware sees
%% worse. Running that inline in init/1 blocked THIS process -- and
%% therefore `gen_server:start_link's caller, and therefore its
%% supervisor's own start_link -- for the whole replay. On weak or loaded
%% hardware that is long enough to plausibly trip an external liveness
%% expectation (a container healthcheck, a supervisor timeout) mid-replay;
%% killing the node there restarts catch-up from offset 0 with nothing
%% carried over, which looks exactly like a non-terminating loop that
%% never gets past the first page. `{continue, catch_up}' lets this
%% process report "started" to its supervisor immediately -- the replay
%% below still runs before this process handles its first real message
%% (continues run before anything already in the mailbox), so ordering is
%% unchanged; only the blocking of `start_link' itself is gone.
%%
%% One thing THIS change did move: a handler can now register WHILE
%% catch-up is running (init/1 no longer blocks the whole node while it
%% replays), where before it never could -- the whole app was blocked on
%% this same replay. Catch-up is therefore gated on `known_types', the
%% snapshot `register_listener/1' returned in init/1, NOT "whichever
%% handlers exist right now": if it used live `get_handlers/1' lookups (as
%% `route_event_with_seq/2' does for the live $all feed), a type that
%% gains its first handler mid-replay would get double-delivered -- once
%% by catch-up for every one of its events scanned AFTER the registration
%% landed, and again in full when the queued `{new_event_type, EventType}'
%% notification runs `backfill_event_type/3' right after catch-up
%% finishes. Gating on the snapshot defers ALL of that type's history to
%% the backfill sweep, uniformly, exactly like a handler registering after
%% catch-up already finished -- one delivery, not two.
handle_continue(catch_up, #state{store_id = StoreId, opts = Opts,
                                  known_types = KnownTypes} = State) ->
    %% Phase 1: Replay historical events (catch-up).
    %% This populates projections with all events stored before this
    %% subscription was created. Events are routed through the same
    %% path as live events, maintaining causal order.
    Seq0 = catch_up_historical(StoreId, KnownTypes),

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

    {noreply, State#state{subscription_id = SubId, seq = Seq0}}.

%% @private
%% New event types are registered dynamically, and this fires only for
%% one that just got its FIRST handler ever (see
%% evoq_event_type_registry:register/2's own doc) — so every handler
%% currently registered for EventType at this moment is late, not a mix
%% of old and new. The $all live subscription only delivers events
%% APPENDED after it was created; it does NOT retroactively cover a type
%% whose handler registers after the initial catch-up phase already ran
%% and scanned past any of that type's events with zero handlers to
%% deliver to (evoq_event_router:route_event_internal/3's routing table
%% lookup happens at delivery time, not at scan time). Without this
%% backfill, a handler in an OTP application that boots after whichever
%% application owns this store's catch-up call — the normal shape for a
%% multi-app vertical-slice umbrella, not an edge case — silently never
%% receives ANY event appended before it registered. Confirmed live in
%% hecate-whiteboard 2026-08-25: a restart with real history logged
%% "Catch-up ... handlers=0" for all 13 events, then this exact
%% "(already covered by $all)" message once its projection handlers
%% registered ~0.8s later — the read model came back completely empty.
handle_info({new_event_type, EventType}, #state{store_id = StoreId, seq = Seq0} = State) ->
    logger:info("[evoq] New event type registered for ~s: ~s -- backfilling its history "
                "(a handler registering after catch-up already ran would otherwise never "
                "see events of this type appended before it subscribed)",
                [StoreId, EventType]),
    Seq1 = backfill_event_type(StoreId, EventType, Seq0),
    {noreply, State#state{seq = Seq1}};

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
%% through the same routing path as live events -- restricted to
%% KnownTypes (see handle_continue/2's comment for why: a type gaining its
%% first handler mid-replay must NOT be routed by catch-up, only by the
%% backfill it triggers, or it is delivered twice).
%% Returns the final sequence number (= total events replayed).
-spec catch_up_historical(atom(), [binary()]) -> non_neg_integer().
catch_up_historical(StoreId, KnownTypes) ->
    BatchSize = 1000,
    catch_up_loop(StoreId, 0, BatchSize, 0, KnownTypes).

-spec catch_up_loop(atom(), non_neg_integer(), pos_integer(), non_neg_integer(),
                     [binary()]) -> non_neg_integer().
catch_up_loop(StoreId, Offset, BatchSize, Seq, KnownTypes) ->
    %% Elapsed time per page, not just event counts: the reckon_db 5.11.1
    %% cache fix looked sufficient against a synthetic 10k-event benchmark
    %% and was materially worse against a real ~87k-event store -- a gap
    %% only visible with per-page timing, which is why it's logged here now
    %% instead of needing a from-scratch repro to diagnose next time.
    {ElapsedUs, Result} = timer:tc(evoq_event_store, read_all_global,
                                    [StoreId, Offset, BatchSize]),
    ElapsedMs = ElapsedUs / 1000,
    case Result of
        {ok, []} ->
            logger:info("[evoq] Catch-up ~s: read_all_global returned 0 events "
                        "at offset ~b (~.1fms)",
                        [StoreId, Offset, ElapsedMs]),
            Seq;
        {ok, Events} ->
            %% Log event types and handler status for diagnostics
            log_catch_up_events(StoreId, Events),
            %% Route only types known at catch-up's start -- see
            %% handle_continue/2. Pagination bookkeeping (below) still uses
            %% the FULL, unfiltered Events/BatchSize so end-of-store
            %% detection and the next Offset are unaffected by the filter.
            Routable = filter_by_type_set(Events, KnownTypes),
            Seq1 = route_events_with_seq(Routable, Seq),
            logger:info("[evoq] Catch-up ~s: routed ~b of ~b events (seq ~b -> ~b) in ~.1fms",
                        [StoreId, length(Routable), length(Events), Seq, Seq1, ElapsedMs]),
            continue_catch_up(length(Events) < BatchSize,
                              StoreId, Offset, Events, BatchSize, Seq1, KnownTypes);
        {error, Reason} ->
            logger:warning("[evoq] Catch-up failed for ~s at offset ~b: ~p (~.1fms)",
                           [StoreId, Offset, Reason, ElapsedMs]),
            Seq
    end.

%% @private Keep only events whose type is in KnownTypes. Same filtering
%% shape as filter_by_type/2, generalized from one type to a snapshot set.
-spec filter_by_type_set([evoq_event() | term()], [binary()]) -> [evoq_event() | term()].
filter_by_type_set(Events, KnownTypes) ->
    [E || E <- Events, lists:member(event_type_or_unknown(E), KnownTypes)].

%% @private Re-scan history for ONE event type and deliver it to whichever
%% handler(s) just registered for it (see the handle_info/2 clause above
%% for why this exists). Filters to EventType only, so already-covered
%% handlers for OTHER types see no redundant delivery. Continues this
%% subscription's own running Seq counter rather than starting a fresh
%% one, so backfilled events get version numbers appended after
%% whatever's already been delivered instead of colliding with them —
%% same reason catch_up_historical/1's own result seeds Seq for the live
%% subscription that starts right after it.
-spec backfill_event_type(atom(), binary(), non_neg_integer()) -> non_neg_integer().
backfill_event_type(StoreId, EventType, Seq0) ->
    BatchSize = 1000,
    backfill_loop(StoreId, EventType, 0, BatchSize, Seq0).

-spec backfill_loop(atom(), binary(), non_neg_integer(), pos_integer(), non_neg_integer()) ->
    non_neg_integer().
backfill_loop(StoreId, EventType, Offset, BatchSize, Seq) ->
    case evoq_event_store:read_all_global(StoreId, Offset, BatchSize) of
        {ok, []} ->
            Seq;
        {ok, Events} ->
            Matching = filter_by_type(Events, EventType),
            Seq1 = route_events_with_seq(Matching, Seq),
            logger:info("[evoq] Backfill ~s/~s: matched ~b of ~b scanned (seq ~b -> ~b)",
                        [StoreId, EventType, length(Matching), length(Events), Seq, Seq1]),
            continue_backfill(length(Events) < BatchSize,
                              StoreId, EventType, Offset, Events, BatchSize, Seq1);
        {error, Reason} ->
            logger:warning("[evoq] Backfill failed for ~s/~s at offset ~b: ~p",
                           [StoreId, EventType, Offset, Reason]),
            Seq
    end.

%% @private Recurse for another batch unless this was the last one.
continue_backfill(true, _StoreId, _EventType, _Offset, _Events, _BatchSize, Seq1) ->
    Seq1;
continue_backfill(false, StoreId, EventType, Offset, Events, BatchSize, Seq1) ->
    backfill_loop(StoreId, EventType, Offset + length(Events), BatchSize, Seq1).

%% @doc Keep only the events matching EventType, in order. Exported for
%% testing (pure, no store needed) -- backfill_loop/5 is the only real
%% caller, and needs a live store to exercise past this point.
-spec filter_by_type([evoq_event() | term()], binary()) -> [evoq_event() | term()].
filter_by_type(Events, EventType) ->
    [E || E <- Events, event_type_or_unknown(E) =:= EventType].

%% @private
log_catch_up_events(StoreId, Events) ->
    lists:foreach(fun(E) -> log_catch_up_event(StoreId, E) end, Events).

log_catch_up_event(StoreId, E) ->
    ET = event_type_or_unknown(E),
    Handlers = evoq_event_type_registry:get_handlers(ET),
    logger:info("[evoq] Catch-up ~s: event_type=~p handlers=~b",
                [StoreId, ET, length(Handlers)]).

event_type_or_unknown(#evoq_event{event_type = T}) -> T;
event_type_or_unknown(_) -> unknown.

%% @private Recurse for another batch unless this was the last one.
continue_catch_up(true, _StoreId, _Offset, _Events, _BatchSize, Seq1, _KnownTypes) ->
    Seq1;
continue_catch_up(false, StoreId, Offset, Events, BatchSize, Seq1, KnownTypes) ->
    catch_up_loop(StoreId, Offset + length(Events), BatchSize, Seq1, KnownTypes).

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
