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
%% 4. For each event, finds the registrants of its type whose history
%%    this subscription has sent (see Registrants below)
%% 5. Routes the event to exactly those, through evoq_event_router (handler
%%    processes) and evoq_pm_router (process managers)
%% 6. Skips events with no such registrant (zero cost)
%%
%% == Registrants ==
%%
%% A registrant is a handler process (event handler or projection) or a
%% process manager, as evoq_event_type_registry names them. This
%% subscription keeps, per store, which registrants are ACTIVE for which
%% types: those whose history from this store it has delivered. Every event
%% goes to the active registrants of its type and to nobody else.
%%
%% Registrants present when this subscription starts are active from the
%% start, and catch-up delivers their history. A registrant that registers
%% later (during catch-up or after it) is announced by the registry; the
%% subscription then delivers the history of that registrant's types up to
%% its own current position to that registrant ALONE, and only then makes it
%% active. Every event therefore reaches every registrant exactly once, in
%% store order, however late it registers relative to other consumers of the
%% same type (evoq #4), and a type only a process manager consumes is routed
%% like any other (evoq #2).
%%
%% == Replay ==
%%
%% Step 1 runs on every boot, so events this node had already consumed
%% before it went down come around again. They are REPLAY: every event at a
%% global position below the persisted $all checkpoint, read at boot before
%% this boot's own ack moves it. Replay carries `replaying => true' in its
%% metadata, from catch-up and from backfill alike. Process managers run
%% handle/3 and apply/2 for it but do not dispatch the commands; event
%% handlers declaring `replay_policy() -> skip' do not see it (see
%% evoq_event_handler). Events at or above the checkpoint were appended
%% while the node was down and are delivered exactly like live ones.
%%
%% Limits: the checkpoint is acked every 200 events and on a clean stop,
%% so after a CRASH up to 199 events delivered since the last ack arrive as
%% new again; exactly-once would need a checkpoint per handler. A node
%% whose checkpoint was never moved (evoq before 1.23.3 never acked it)
%% sees its whole history as new once more, on its first boot with 1.24.0.
%% An unreadable checkpoint is treated as "nothing is replay", logged.
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
         filter_by_type/2]).

%% gen_server callbacks
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2]).

-record(state, {
    store_id :: atom(),
    subscription_id :: binary() | undefined,
    opts :: map(),
    %% Monotonically increasing sequence number for events delivered
    %% through this subscription, put in metadata as `version'. It restarts
    %% at 0 on every boot and counts only events with a handler, so nothing
    %% may persist it: projections checkpoint on `global_position' (see
    %% route_event_at/4).
    seq :: non_neg_integer(),
    %% {Registrant, EventType} for every registrant whose history of that
    %% type this subscription has delivered: the only registrants an event
    %% of the type is routed to. See the module doc's Registrants section.
    active :: active(),
    %% The identity of each registrant this subscription has seen (a
    %% handler's module, a process manager's {pm, Module}). Handler
    %% processes in it are monitored, so a dead one leaves `active'.
    identities :: #{evoq_event_type_registry:registrant() =>
                        evoq_event_type_registry:identity()},
    %% For each identity whose registrant died or withdrew this boot, how
    %% far this subscription had routed to it: its next incarnation's
    %% backfill marks everything below that replay, as SeenUpTo does for
    %% the boot (evoq #4, review round 1).
    reach :: #{evoq_event_type_registry:identity() => non_neg_integer()},
    %% How many events this subscription has scanned/consumed so far, in
    %% real global store order -- NOT `seq' (which only counts ones that
    %% actually had a handler). This is the position acknowledged to the
    %% persisted $all subscription (evoq_subscriptions:ack/4) so a FUTURE
    %% restart's catch-up resumes from here instead of replaying the whole
    %% store again. See handle_continue/2 and handle_info/2's comments.
    offset :: non_neg_integer(),
    %% Offset value as of the last successful (or attempted) ack. Lets
    %% handle_info/2 coalesce acks (see ?ACK_EVERY_N_EVENTS) instead of
    %% making a synchronous, retrying, Raft-committing gateway call for
    %% every single live event.
    last_acked :: non_neg_integer(),
    %% The persisted $all checkpoint as this boot found it, before its own
    %% pre-subscribe ack moved it: how far this node had consumed the
    %% store before it went down. Catch-up and backfill mark every event
    %% below it `replaying => true'. See seen_up_to/1.
    seen_up_to :: non_neg_integer(),
    %% The ids of the last ?RECENT_IDS events this subscription consumed,
    %% oldest first, and the same ids as a set. A live event whose id is in
    %% it is a second delivery (see handle_info/2) and is dropped before it
    %% is positioned: counting it would move every later live position,
    %% the offset acked to the store and the next boot's SeenUpTo up by one.
    recent :: {queue:queue(binary()), #{binary() => true}}
}).

%% reckon-db's own catch-up reads 500 events a page, so a duplicate burst
%% from its trigger/catch-up overlap stays well inside this window.
-define(RECENT_IDS, 2000).

%% The most ids the redelivery window holds when it is widened after a
%% failed pre-subscribe ack (see recent_tail/4). About 150 bytes each.
-define(REDELIVERY_WINDOW_CAP, 100000).

%% Events read per page by catch-up and backfill.
-define(BATCH_SIZE, 1000).

%% {Registrant, EventType} pairs: the registrants an event of the type is
%% routed to (see the module doc's Registrants section).
-type active() :: #{{evoq_event_type_registry:registrant(), binary()} => true}.

%% Every live event acked individually would mean one synchronous
%% gen_server:call (reckon_db_subscriptions:ack/4, a Khepri/Raft commit,
%% retried up to ~30s on transient gateway trouble per
%% reckon_gater_retry) PER EVENT, serialized in this process's own
%% message loop -- a real throughput ceiling under sustained live load
%% that plain per-event delivery never had. Coalescing trades a small,
%% bounded increase in what a restart might re-scan (at most this many
%% events, on top of Phase 1's own always-from-0 rescan, which already
%% dwarfs it) for acking at a steady, load-independent rate instead of
%% once per message.
-define(ACK_EVERY_N_EVENTS, 200).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a store subscription with default options.
-spec start_link(atom()) -> {ok, pid()} | {error, term()}.
start_link(StoreId) ->
    start_link(StoreId, #{}).

%% @doc Start a store subscription with options.
%%
%% No options are currently read from Opts -- catch-up always starts at
%% 0 and the live $all subscription's own starting point is always
%% whatever catch_up_historical/2 actually scanned up to (see
%% handle_continue/2), not a caller-supplied position. Opts is still
%% accepted and threaded through (subscribe_to_all/3 receives it) for a
%% future option this shape doesn't need yet -- e.g. pool_size.
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
    %% Trap exits so a supervisor's shutdown runs terminate/2, which acks the
    %% position routed so far. Without it the "ack on a clean stop" never ran
    %% and every restart redelivered up to ?ACK_EVERY_N_EVENTS - 1 handled
    %% events (macula-realm#64).
    process_flag(trap_exit, true),
    %% Register as a listener with the type registry.
    %% We still register so we know about new types, but we no longer
    %% need to create per-type subscriptions — we subscribe to $all.
    %% The registrations that exist now are active from the start: catch-up
    %% delivers their history. Every later one is announced to this process
    %% and backfilled first (see handle_continue/2).
    {ok, Registrations} = evoq_event_type_registry:register_listener(self()),
    Active = maps:from_list([{{R, T}, true} || {R, Types, _} <- Registrations, T <- Types]),
    Identities = lists:foldl(fun({R, _, I}, Acc) -> identify(R, I, Acc) end, #{},
                             Registrations),

    {ok, #state{
        store_id = StoreId,
        subscription_id = undefined,
        opts = Opts,
        seq = 0,
        active = Active,
        identities = Identities,
        reach = #{},
        offset = 0,
        last_acked = 0,
        seen_up_to = 0,
        recent = {queue:new(), #{}}
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
%% this same replay. Catch-up therefore routes only to the registrants that
%% were active when it started: one registering mid-replay is not active,
%% gets nothing from catch-up, and gets its whole history from the backfill
%% its queued `{new_registrant, _, _}' runs right after catch-up finishes --
%% one delivery, in order, not part of it twice.
%%
%% == Why subscribe_to_all/3 is handed Offset0, and why handle_info/2 acks ==
%%
%% `evoq_subscriptions:ack/4' exists and used to go entirely unused here.
%% Two consequences, confirmed live in production (three services each had
%% a real `evoq_event_handler' with an unconditional mesh-publish side
%% effect and no dedup of their own -- this was not a theoretical gap):
%%
%% 1. `subscribe_to_all's underlying persisted subscription
%%    (reckon_db_subscriptions) runs its OWN catch-up on every FRESH
%%    subscribe -- a full second replay of everything this process's own
%%    Phase 1 above just finished delivering, moments earlier, in the same
%%    boot. Fixed by handing it Offset0 (the real global position Phase 1
%%    scanned up to) as its starting point, so it has nothing left to
%%    replay -- see `catch_up_historical/2's own doc for why Offset0 is
%%    NOT Seq0 (Seq counts delivered events; Offset counts scanned ones,
%%    the number `reckon_db_subscriptions' actually paginates on).
%% 2. On every RESTART after the first, `reckon_db_subscriptions'
%%    reconnect path (`reregister_subscriber/4') ignores whatever
%%    start_from this process passes -- it resumes from the PERSISTED
%%    subscription's own checkpoint instead. That checkpoint was NEVER
%%    updated (ack/4 was dead code), so it stayed exactly where the first
%%    boot ever left it: 0. Every restart, forever, replayed the entire
%%    store's history again. Fixed by acking Offset0 BEFORE calling
%%    subscribe_to_all/3 below (not just relying on handle_info/2's own
%%    ongoing acks): on a reconnect this moves the PERSISTED checkpoint
%%    to what Phase 1 just covered before reregister_subscriber/4 ever
%%    reads it, so this boot's own reconnect catch-up has nothing left to
%%    replay either -- confirmed empirically (Fable), not just reasoned:
%%    without this pre-ack, a restart still double-delivers every event
%%    scanned between the old checkpoint and Offset0, once via Phase 1's
%%    own rescan and once via the reconnect catch-up, exactly the
%%    failure this fix exists to close. Acking here on a FRESH boot (no
%%    persisted subscription yet) is a harmless no-op --
%%    reckon_db_subscriptions:ack/4 returns `subscription_not_found',
%%    whitelisted as non-retriable, and `start_from => Offset0' below
%%    already does that case's job. handle_info/2 continues acking
%%    afterward so a LATER restart, once live traffic has moved the
%%    position further, doesn't fall back to replaying everything since
%%    Offset0.
%%
%% Together these close both ends: a truly fresh store no longer
%% double-replays on its first boot, and a long-running store no longer
%% replays its whole history on any restart after that.
handle_continue(catch_up, #state{store_id = StoreId, opts = Opts,
                                  active = Active} = State) ->
    %% Phase 1: Replay historical events (catch-up).
    %% This populates projections with all events stored before this
    %% subscription was created. Events are routed through the same
    %% path as live events, maintaining causal order.
    %% Read BEFORE the ack below, which overwrites it with this boot's own
    %% position and would make everything look new.
    SeenUpTo = seen_up_to(StoreId),
    {Seq0, Offset0} = catch_up_historical(StoreId, Active, SeenUpTo),
    Acked = pre_subscribe_ack(StoreId, Offset0),

    %% Phase 2: Subscribe to new events going forward, starting from
    %% Offset0 -- everything before it was just delivered above.
    SubId = case subscribe_to_all(StoreId, Opts, Offset0) of
        {ok, Id} ->
            Id;
        {error, Reason} ->
            logger:warning("[evoq] Failed to subscribe to $all for ~s: ~p",
                           [StoreId, Reason]),
            undefined
    end,

    logger:info("[evoq] Store subscription started for ~s (catch-up: ~b events "
                "routed, ~b scanned, the first ~b of them replay)",
                [StoreId, Seq0, Offset0, min(SeenUpTo, Offset0)]),

    {noreply, State#state{subscription_id = SubId, seq = Seq0, offset = Offset0,
                           last_acked = Offset0, seen_up_to = SeenUpTo,
                           recent = recent_tail(StoreId, Offset0, SeenUpTo, Acked)}}.

%% @private
%% A registrant registered (or withdrew) after this subscription started.
%%
%% The $all live subscription only delivers events APPENDED after it was
%% created; it does not retroactively cover a registrant that registers
%% after catch-up already scanned past the history of its types. Without
%% this backfill, a handler in an OTP application that boots after whichever
%% application owns this store's catch-up call -- the normal shape for a
%% multi-app vertical-slice umbrella, not an edge case -- silently never
%% receives ANY event appended before it registered. Confirmed live in a
%% service on 2026-08-25: the read model came back completely empty.
%%
%% The backfill goes to the new registrant ALONE, for every type of its
%% registration, whether or not another registrant already holds the type,
%% and covers the store up to this subscription's own position: everything
%% below it has been routed, everything from it on arrives live. Until the
%% backfill has run the registrant is not active, so no event reaches it out
%% of order or twice. It ran only for a type's FIRST handler, delivered to
%% whoever was registered at the time, and a second consumer of a type got
%% no history at all (evoq #4).
%%
%% Registrations queued behind this one are taken in the same pass, so a
%% boot that registers many handlers at once scans the store once.
%%
%% A registrant names its identity and where its history starts (see
%% evoq_event_type_registry:register_all/3). The backfill starts at `from',
%% so a projection resuming at its checkpoint is not handed, through the
%% node's event router, the history it already holds. And everything below
%% how far this subscription had routed to the same identity before (a
%% handler the supervisor restarted) is marked replay, so a handler with
%% `replay_policy() -> skip' does not repeat a side effect of its last
%% incarnation.
handle_info({new_registrant, _, _, _} = Message, State) ->
    {noreply, register_pending(take_registrations([Message]), State)};

handle_info({registrant_left, _, _} = Message, State) ->
    {noreply, register_pending(take_registrations([Message]), State)};

handle_info({'DOWN', _Ref, process, Pid, _Reason},
            #state{active = Active, identities = Identities, reach = Reach,
                   offset = Offset} = State) ->
    {noreply, State#state{active = maps:filter(fun({R, _}, _) -> R =/= Pid end, Active),
                          identities = maps:remove(Pid, Identities),
                          reach = reached(Pid, Identities, Offset, Reach)}};

%% This is the SAME message shape the $all subscription's own catch-up
%% delivers (reckon_db_subscriptions:send_filtered_events/2) and its live
%% feed delivers -- one handler for both, as it always was. What changed:
%% acking progress periodically (every ?ACK_EVERY_N_EVENTS, not every
%% single message -- see that macro's own comment for why per-event
%% acking is a real throughput hazard, not just unnecessary), so a future
%% restart's reckon_db-side catch-up (reregister_subscriber/4) resumes
%% from near here instead of from 0 -- see handle_continue/2's comment
%% for the full mechanism this closes. A failed ack is logged and NOT
%% fatal: it costs the next restart a bigger (still correct, since
%% catch-up is idempotent by construction) replay, not a missed event.
%%
%% reckon-db arms its trigger before it starts its own catch-up and says an
%% event written in between may be delivered twice, and a reconnect whose
%% pre-subscribe ack failed redelivers from the older checkpoint. An event
%% whose id this subscription consumed recently is dropped here, before it
%% is positioned or counted: live positions are counted, not read, so one
%% counted duplicate put every later live event one position too high, and
%% after a restart the checkpoint then covered an event appended while the
%% node was down.
handle_info({events, Events}, #state{store_id = StoreId, seq = Seq0,
                                      offset = Offset0,
                                      last_acked = LastAcked,
                                      active = Active,
                                      recent = Recent0} = State) when is_list(Events) ->
    {Fresh, Recent1} = drop_seen(Events, Recent0),
    %% Live events carry their global position too: the offset this
    %% subscription has counted is where they sit in the store's global log.
    %% Nothing live is replay, so SeenUpTo is 0.
    Seq1 = route_positioned(StoreId, positioned(Fresh, Offset0), Seq0, 0, Active),
    Offset1 = Offset0 + length(Fresh),
    NewLastAcked = maybe_ack(StoreId, Offset1, LastAcked),
    {noreply, State#state{seq = Seq1, offset = Offset1, last_acked = NewLastAcked,
                          recent = Recent1}};

%% Trapping exits (see init/1) must not swallow a linked process's death:
%% stop with its reason, as the untrapped process used to die with it. The
%% parent's exit never gets here; gen_server handles it and runs terminate/2.
handle_info({'EXIT', _Pid, Reason}, State) ->
    {stop, Reason, State};

handle_info(_Info, State) ->
    {noreply, State}.

%% @private Every registration message already queued, in arrival order,
%% after the ones in Acc (newest first).
take_registrations(Acc) ->
    receive
        {new_registrant, _, _, _} = Message -> take_registrations([Message | Acc]);
        {registrant_left, _, _} = Message -> take_registrations([Message | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.

%% @private Apply registration messages in order, backfill the new
%% registrants in one pass, then make them active.
register_pending(Messages, #state{store_id = StoreId, seq = Seq0, offset = Offset,
                                  active = Active0, identities = Ids0,
                                  reach = Reach0} = State) ->
    {Pending, Info, Active1, Ids1, Reach1} =
        lists:foldl(fun(M, Acc) -> pending(M, State, Acc) end,
                    {#{}, #{}, Active0, Ids0, Reach0}, Messages),
    Seq1 = backfill(StoreId, Pending, Info, Offset, Seq0),
    State#state{seq = Seq1, active = maps:merge(Active1, Pending), identities = Ids1,
                reach = Reach1}.

%% @private Fold one message into {Pending, Info, Active, Identities,
%% Reach}. A new registrant's types it is not active for yet become pending,
%% with Info saying where its backfill starts and below which position it is
%% replay. A withdrawal leaves Pending and Active, and records how far the
%% registrant was reached. A registrant on another node is served by its own
%% node's subscription.
pending({new_registrant, Pid, _Types, _Info}, _State, Acc)
        when is_pid(Pid), node(Pid) =/= node() ->
    Acc;
pending({new_registrant, Registrant, Types, #{identity := Identity, from := From}},
        #state{active = Active0, seen_up_to = SeenUpTo}, {Pending, Info, Active, Ids, Reach}) ->
    New = [{{Registrant, T}, true} || T <- Types, not is_map_key({Registrant, T}, Active0)],
    ReplayBelow = max(SeenUpTo, maps:get(Identity, Reach, 0)),
    {maps:merge(Pending, maps:from_list(New)), Info#{Registrant => {From, ReplayBelow}},
     Active, identify(Registrant, Identity, Ids), Reach};
pending({registrant_left, Registrant, Types}, #state{offset = Offset},
        {Pending, Info, Active, Ids, Reach}) ->
    Gone = [{Registrant, T} || T <- Types],
    {maps:without(Gone, Pending), Info, maps:without(Gone, Active), Ids,
     reached(Registrant, Ids, Offset, Reach)}.

%% @private Remember a registrant's identity, monitoring a handler process
%% the first time it is seen.
identify(Pid, Identity, Ids) when is_pid(Pid), not is_map_key(Pid, Ids) ->
    _ = erlang:monitor(process, Pid),
    Ids#{Pid => Identity};
identify(Registrant, Identity, Ids) ->
    Ids#{Registrant => Identity}.

%% @private Everything below Offset has been routed to this registrant's
%% identity: its next incarnation is not handed that as new.
reached(Registrant, Ids, Offset, Reach) when is_map_key(Registrant, Ids) ->
    Identity = maps:get(Registrant, Ids),
    Reach#{Identity => max(Offset, maps:get(Identity, Reach, 0))};
reached(_Registrant, _Ids, _Offset, Reach) ->
    Reach.

%% @private Split Events into those not consumed recently, in order, and
%% remember their ids. A duplicate inside one batch is dropped too. An event
%% without an id cannot be recognised and always goes through.
-spec drop_seen([evoq_event() | term()], {queue:queue(binary()), #{binary() => true}}) ->
    {[evoq_event() | term()], {queue:queue(binary()), #{binary() => true}}}.
drop_seen(Events, Recent) ->
    {FreshRev, Recent1} = lists:foldl(fun keep_unseen/2, {[], Recent}, Events),
    {lists:reverse(FreshRev), Recent1}.

keep_unseen(E, {Fresh, {_, Ids} = Recent}) ->
    keep_unseen(event_id_of(E), E, Fresh, Recent, Ids).

keep_unseen(undefined, E, Fresh, Recent, _Ids) ->
    {[E | Fresh], Recent};
keep_unseen(Id, _E, Fresh, Recent, Ids) when is_map_key(Id, Ids) ->
    {Fresh, Recent};
keep_unseen(Id, E, Fresh, Recent, _Ids) ->
    {[E | Fresh], remember(Id, Recent)}.

event_id_of(#evoq_event{event_id = Id}) -> Id;
event_id_of(_Other) -> undefined.

%% @private Add Id, dropping the oldest once ?RECENT_IDS are held.
remember(Id, {Queue, Ids}) ->
    trim({queue:in(Id, Queue), Ids#{Id => true}}).

trim({Queue, Ids}) when map_size(Ids) > ?RECENT_IDS ->
    {{value, Oldest}, Queue1} = queue:out(Queue),
    {Queue1, maps:remove(Oldest, Ids)};
trim(Recent) ->
    Recent.

%% @private The ids of the events catch-up scanned that the live path may
%% deliver again, so a redelivery of them is recognised.
%%
%% With the pre-subscribe ack in place, a reconnect resumes at Offset and
%% only reckon-db's trigger/catch-up overlap can repeat anything: the last
%% ?RECENT_IDS ids cover it. When that ack FAILED, the persisted checkpoint
%% is still the one this boot read, SeenUpTo, and a reconnect redelivers
%% everything from it: every event appended while the node was down. The
%% window then reaches back to SeenUpTo, however far that is, and is not
%% trimmed while it is seeded (evoq #8). A store with no subscription yet
%% has nothing to reconnect to; its ack is not a failure (see acked/1).
recent_tail(_StoreId, 0, _SeenUpTo, _Acked) ->
    {queue:new(), #{}};
recent_tail(StoreId, Offset, SeenUpTo, Acked) ->
    seed_window(StoreId, window_start(Offset, SeenUpTo, acked(Acked)), Offset).

window_start(Offset, _SeenUpTo, true) -> max(0, Offset - ?RECENT_IDS);
window_start(Offset, SeenUpTo, false) ->
    capped_start(min(SeenUpTo, max(0, Offset - ?RECENT_IDS)), Offset, window_cap()).

%% @private The widened window holds at most `redelivery_window_cap' ids
%% (default ?REDELIVERY_WINDOW_CAP), so a long outage costs bounded memory.
%% Past the cap it holds the newest, and says which positions a redelivery
%% will not be recognised at: those would be counted as new again.
capped_start(Start, Offset, Cap) when Offset - Start =< Cap ->
    Start;
capped_start(Start, Offset, Cap) ->
    logger:warning(#{what => evoq_redelivery_window_capped,
                     cap => Cap,
                     unrecognised_from => Start,
                     unrecognised_to => Offset - Cap}),
    Offset - Cap.

window_cap() ->
    application:get_env(evoq, redelivery_window_cap, ?REDELIVERY_WINDOW_CAP).

%% @private The ack before subscribe, tried once more if it fails: reckon-db
%% resumes a reconnect at the checkpoint it leaves, and a failure here is
%% usually a moment of gateway trouble.
pre_subscribe_ack(StoreId, Offset) ->
    ack_again(acked(ack_progress(StoreId, Offset)), StoreId, Offset).

ack_again(true, _StoreId, _Offset) -> ok;
ack_again(false, StoreId, Offset) -> ack_progress(StoreId, Offset).

%% @private Whether the pre-subscribe ack left the persisted checkpoint at
%% this boot's position. A brand new subscription has none to move yet; it
%% starts at the `start_from' this subscription hands it.
acked(ok) -> true;
acked({error, {subscription_not_found, _}}) -> true;
acked({error, _}) -> false.

%% @private Read [From, To) page by page and hold every id in it. A page
%% that cannot be read is tried once more, since it fails in the same
%% moment of gateway trouble the failed ack did; after that the window
%% holds what was read, and says so.
seed_window(StoreId, From, To) ->
    seed_window(StoreId, From, To, {queue:new(), #{}}).

seed_window(_StoreId, From, To, Recent) when From >= To ->
    Recent;
seed_window(StoreId, From, To, Recent) ->
    seed_page(read_seed_page(StoreId, From, To, 2), StoreId, From, To, Recent).

read_seed_page(StoreId, From, To, Tries) ->
    retry_seed_read(evoq_event_store:read_all_global(StoreId, From, min(?BATCH_SIZE, To - From)),
                    StoreId, From, To, Tries - 1).

retry_seed_read({error, _}, StoreId, From, To, Tries) when Tries > 0 ->
    read_seed_page(StoreId, From, To, Tries);
retry_seed_read(Result, _StoreId, _From, _To, _Tries) ->
    Result.

seed_page({ok, []}, _StoreId, _From, _To, Recent) ->
    Recent;
seed_page({ok, Events}, StoreId, From, To, Recent) ->
    seed_window(StoreId, From + length(Events), To, lists:foldl(fun hold/2, Recent, Events));
seed_page({error, Reason}, StoreId, From, _To, Recent) ->
    logger:warning("[evoq] Could not read the catch-up tail of ~s at ~b to recognise "
                   "redeliveries: ~p", [StoreId, From, Reason]),
    Recent.

%% @private Remember an event's id without trimming the window.
hold(E, {Queue, Ids} = Recent) ->
    hold(event_id_of(E), Queue, Ids, Recent).

hold(undefined, _Queue, _Ids, Recent) -> Recent;
hold(Id, _Queue, Ids, Recent) when is_map_key(Id, Ids) -> Recent;
hold(Id, Queue, Ids, _Recent) -> {queue:in(Id, Queue), Ids#{Id => true}}.

%% @private Acks only once at least ?ACK_EVERY_N_EVENTS have accumulated
%% since the last ack, returning whichever Offset is now the acked one
%% (so the caller's `last_acked' stays accurate whether or not this call
%% actually acked).
maybe_ack(StoreId, Offset, LastAcked) when Offset - LastAcked >= ?ACK_EVERY_N_EVENTS ->
    _ = ack_progress(StoreId, Offset),
    Offset;
maybe_ack(_StoreId, _Offset, LastAcked) ->
    LastAcked.

%% @private
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
%% A clean stop (unlike a crash/kill, which skips terminate/2 entirely
%% and is exactly the case ?ACK_EVERY_N_EVENTS coalescing already
%% tolerates) can flush its up-to-date position for free, so the next
%% boot's reconnect catch-up has that much less to redeliver.
terminate(_Reason, #state{store_id = StoreId, offset = Offset,
                          last_acked = LastAcked}) ->
    ack_progress_if_ahead(StoreId, Offset, LastAcked),
    evoq_event_type_registry:unregister_listener(self()),
    logger:info("[evoq] Store subscription stopping for ~s", [StoreId]),
    ok.

ack_progress_if_ahead(StoreId, Offset, LastAcked) when Offset > LastAcked ->
    _ = ack_progress(StoreId, Offset),
    ok;
ack_progress_if_ahead(_StoreId, _Offset, _LastAcked) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private Replay all historical events from the store.
%% Reads events in batches via read_all_global and routes each batch
%% through the same routing path as live events, to the registrants active
%% when catch-up started (see handle_continue/2's comment for why: a
%% registrant arriving mid-replay must NOT be routed to by catch-up, only by
%% the backfill it triggers, or it gets part of its history twice and out
%% of order).
%% Returns `{Seq, Offset}': Seq is how many events were actually routed
%% (had a handler) -- carried into live routing so version numbers stay
%% monotonic across the catch-up/live boundary. Offset is how many events
%% were SCANNED, routed or not -- the real global store position, which is
%% what `subscribe_to_all/3' hands the persisted $all subscription as its
%% own starting point (see handle_continue/2's comment for why these two
%% counters must not be conflated: using Seq there would make the
%% persisted subscription re-scan every event catch-up skipped for having
%% no handler, every single boot).
%%
%% Events at a global position below SeenUpTo are replay (see
%% seen_up_to/1) and are routed with `replaying => true'.
-spec catch_up_historical(atom(), active(), non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
catch_up_historical(StoreId, Active, SeenUpTo) ->
    catch_up_loop(StoreId, 0, 0, Active, SeenUpTo).

-spec catch_up_loop(atom(), non_neg_integer(), non_neg_integer(), active(),
                    non_neg_integer()) ->
    {non_neg_integer(), non_neg_integer()}.
catch_up_loop(StoreId, Offset, Seq, Active, SeenUpTo) ->
    %% Elapsed time per page, not just event counts: the reckon_db 5.11.1
    %% cache fix looked sufficient against a synthetic 10k-event benchmark
    %% and was materially worse against a real ~87k-event store -- a gap
    %% only visible with per-page timing, which is why it's logged here now
    %% instead of needing a from-scratch repro to diagnose next time.
    {ElapsedUs, Result} = timer:tc(evoq_event_store, read_all_global,
                                    [StoreId, Offset, ?BATCH_SIZE]),
    ElapsedMs = ElapsedUs / 1000,
    case Result of
        {ok, []} ->
            logger:info("[evoq] Catch-up ~s: read_all_global returned 0 events "
                        "at offset ~b (~.1fms)",
                        [StoreId, Offset, ElapsedMs]),
            {Seq, Offset};
        {ok, Events} ->
            %% Log event types and handler status for diagnostics
            log_catch_up_events(StoreId, Events),
            %% Route to the registrants active at catch-up's start only --
            %% see handle_continue/2.
            Seq1 = route_positioned(StoreId, positioned(Events, Offset), Seq, SeenUpTo,
                                    Active),
            logger:info("[evoq] Catch-up ~s: routed ~b of ~b events (seq ~b -> ~b) in ~.1fms",
                        [StoreId, Seq1 - Seq, length(Events), Seq, Seq1, ElapsedMs]),
            continue_catch_up(length(Events) < ?BATCH_SIZE,
                              StoreId, Offset, Events, Seq1, Active, SeenUpTo);
        {error, Reason} ->
            logger:warning("[evoq] Catch-up failed for ~s at offset ~b: ~p (~.1fms)",
                           [StoreId, Offset, Reason, ElapsedMs]),
            {Seq, Offset}
    end.

%% @private Deliver the history of the pending {Registrant, Type} pairs to
%% those registrants alone, in ONE pass over the store, in global order, up
%% to Offset: everything below it has been routed by this subscription,
%% everything from it on arrives live once the registrants are active. A
%% pass per registrant or per type delivered the history of one type and
%% then of the next, and a projection checkpointing on the global position
%% then skipped every event of its second type below the first type's last.
%%
%% Replay is marked exactly as in catch_up_historical/3: this is the path a
%% handler registering after catch-up (every handler in an app booting
%% after the one owning the store) gets ALL its history through.
%%
%% Each registrant's history starts at its own `from' and is replay below its
%% own threshold (Info); the pass starts at the lowest `from'.
-spec backfill(atom(), active(), #{term() => {non_neg_integer(), non_neg_integer()}},
               non_neg_integer(), non_neg_integer()) -> non_neg_integer().
backfill(_StoreId, Pending, _Info, _Offset, Seq) when map_size(Pending) =:= 0 ->
    Seq;
backfill(StoreId, Pending, Info, Offset, Seq) ->
    Registrants = lists:usort([R || {R, _} <- maps:keys(Pending)]),
    Start = lists:min([element(1, maps:get(R, Info)) || R <- Registrants]),
    logger:info("[evoq] Backfilling ~s from ~b up to ~b for ~p",
                [StoreId, Start, Offset, Registrants]),
    backfill_page(StoreId, Pending, Info, Start, Offset, Seq).

backfill_page(_StoreId, _Pending, _Info, From, To, Seq) when From >= To ->
    Seq;
backfill_page(StoreId, Pending, Info, From, To, Seq) ->
    case evoq_event_store:read_all_global(StoreId, From, min(?BATCH_SIZE, To - From)) of
        {ok, []} ->
            Seq;
        {ok, Events} ->
            Seq1 = backfill_events(StoreId, positioned(Events, From), Seq, Pending, Info),
            backfill_page(StoreId, Pending, Info, From + length(Events), To, Seq1);
        {error, Reason} ->
            %% The registrants become active all the same: holding them back
            %% would cost them every live event as well. Their history from
            %% here on is missing, and this says so.
            logger:error("[evoq] Backfill failed for ~s at offset ~b: ~p; the registrants "
                         "~p miss the history from there", [StoreId, From, Reason,
                         lists:usort([R || {R, _} <- maps:keys(Pending)])]),
            Seq
    end.

backfill_events(_StoreId, [], Seq, _Pending, _Info) ->
    Seq;
backfill_events(StoreId, [{Position, E} | Rest], Seq, Pending, Info) ->
    backfill_events(StoreId, Rest, backfill_event(StoreId, E, Seq, Position, Pending, Info),
                    Pending, Info).

%% @private Route one event of a backfill to the pending registrants whose
%% history it belongs to (at or after their `from'), marked replay for those
%% whose threshold it is below.
backfill_event(StoreId, #evoq_event{} = E, Seq, Position, Pending, Info) ->
    {Event, Metadata0} = evoq_event_to_routable(E),
    {Handlers, PMs} = targets(Event, Pending),
    Due = fun(R) -> Position >= element(1, maps:get(R, Info)) end,
    Replay = fun(R) -> Position < element(2, maps:get(R, Info)) end,
    {ReplayH, FreshH} = lists:partition(Replay, lists:filter(Due, Handlers)),
    {ReplayPM, FreshPM} = lists:partition(fun(M) -> Replay({pm, M}) end,
                                          [M || M <- PMs, Due({pm, M})]),
    Extra = #{global_position => Position, store_id => StoreId},
    max(deliver({ReplayH, ReplayPM}, Event, routed_metadata(Metadata0, Seq, true, Extra), Seq),
        deliver({FreshH, FreshPM}, Event, routed_metadata(Metadata0, Seq, false, Extra), Seq));
backfill_event(_StoreId, _Other, Seq, _Position, _Pending, _Info) ->
    Seq.

%% @doc Keep only the events matching EventType, in order. Exported for
%% testing (pure, no store needed).
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
continue_catch_up(true, _StoreId, Offset, Events, Seq1, _Active, _SeenUpTo) ->
    {Seq1, Offset + length(Events)};
continue_catch_up(false, StoreId, Offset, Events, Seq1, Active, SeenUpTo) ->
    catch_up_loop(StoreId, Offset + length(Events), Seq1, Active, SeenUpTo).

%% @private Subscribe to the $all stream on the store, starting from
%% Offset0 -- the real position Phase 1's catch_up_historical/2 already
%% scanned up to. Uses by_stream subscription type with <<"$all">>
%% selector, which matches events in ALL streams (global store order).
%%
%% Offset0 only controls the checkpoint reckon_db_subscriptions:subscribe/5
%% assigns a BRAND NEW subscription (store_and_setup/6's own Draft); on a
%% RECONNECT (subscription already persisted from an earlier boot) it is
%% ignored -- reregister_subscriber/4 resumes from whatever checkpoint is
%% already on disk instead, which is why handle_info/2 acking on every
%% batch matters just as much as this does. See handle_continue/2's
%% comment for the full mechanism.
-spec subscribe_to_all(atom(), map(), non_neg_integer()) -> {ok, binary()} | {error, term()}.
subscribe_to_all(StoreId, _Opts, Offset0) ->
    SubName = subscription_name(StoreId),
    evoq_subscriptions:subscribe(
        StoreId, stream, <<"$all">>, SubName,
        #{subscriber_pid => self(), start_from => Offset0}
    ).

%% @private Best-effort: persists how far this subscription has actually
%% consumed the store, so a future restart's catch-up resumes from here
%% instead of the beginning. A failure here is not fatal -- see
%% handle_info/2's comment -- but the pre-subscribe ack's result decides how
%% far back redeliveries are recognised (see recent_tail/4), so it is
%% returned.
-spec ack_progress(atom(), non_neg_integer()) -> ok | {error, term()}.
ack_progress(StoreId, Offset) ->
    ack_result(evoq_subscriptions:ack(StoreId, subscription_name(StoreId), undefined, Offset),
               StoreId, Offset).

ack_result(ok, _StoreId, _Offset) ->
    ok;
ack_result({error, Reason} = Error, StoreId, Offset) ->
    logger:warning("[evoq] Failed to ack progress (offset ~b) for ~s: ~p",
                   [Offset, StoreId, Reason]),
    Error.

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
%% Metadata carries the event's own stream version; the subscription's own
%% routing (route_event_at/4) adds `global_position', which is what a
%% projection checkpoints on.
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

%% @private Pairs each event of a page read at Offset with its global
%% store position, the unit seen_up_to/1's checkpoint is counted in.
-spec positioned([evoq_event() | term()], non_neg_integer()) ->
    [{non_neg_integer(), evoq_event() | term()}].
positioned(Events, Offset) ->
    lists:zip(lists:seq(Offset, Offset + length(Events) - 1), Events).

%% @private Route positioned events to the registrants in Active, marking
%% those below SeenUpTo replay. The store is threaded through so every
%% delivery names the store it came from: a handler's acknowledgment is
%% keyed on (store, stream) and an aggregate id alone is not unique across
%% stores.
-spec route_positioned(atom(), [{non_neg_integer(), evoq_event() | term()}], non_neg_integer(),
                       non_neg_integer(), active()) -> non_neg_integer().
route_positioned(_StoreId, [], Seq, _SeenUpTo, _Active) ->
    Seq;
route_positioned(StoreId, [{Position, E} | Rest], Seq, SeenUpTo, Active) ->
    route_positioned(StoreId, Rest,
                     route_event_at(StoreId, E, Seq, Position, Position < SeenUpTo, Active),
                     SeenUpTo, Active).

%% @private Route a single event with sequence-based version override and no
%% global position. Kept for route_events_with_seq/2; every path the
%% subscription itself routes goes through route_event_at/4.
-spec route_event_with_seq(evoq_event() | term(), non_neg_integer()) -> non_neg_integer().
route_event_with_seq(E, Seq) ->
    route_event_with_seq(E, Seq, false).

%% @private Route an event at its global position in the store to the
%% registrants of its type in Active. The position is the index of the
%% event in the store's global log, the same in every boot, whatever
%% handlers exist. It goes into metadata as `global_position', which is what
%% a projection checkpoints on (evoq #1). `version' stays the per-boot `Seq'
%% for anything that already reads it, but nothing may persist `Seq': it
%% restarts at 0 on every boot and counts only events that were routed.
-spec route_event_at(atom(), evoq_event() | term(), non_neg_integer(), non_neg_integer(),
                     boolean(), active()) -> non_neg_integer().
route_event_at(StoreId, #evoq_event{} = E, Seq, Position, Replaying, Active) ->
    {Event, Metadata0} = evoq_event_to_routable(E),
    deliver(targets(Event, Active), Event,
            routed_metadata(Metadata0, Seq, Replaying,
                            #{global_position => Position, store_id => StoreId}),
            Seq);
route_event_at(_StoreId, _Other, Seq, _Position, _Replaying, _Active) ->
    Seq.

%% @private The handler processes and process managers in Active for this
%% event: handlers by the type the event router delivers it as (after
%% upcasting), process managers by the stored type, as the PM router
%% correlates it.
targets(#{event_type := Type} = Event, Active) ->
    {DeliveredType, Pids} = evoq_event_router:delivery_targets(Event),
    {[P || P <- lists:usort(Pids), is_map_key({P, DeliveredType}, Active)],
     [M || M <- evoq_event_type_registry:get_process_managers(Type),
           is_map_key({{pm, M}, Type}, Active)]}.

%% @private Hand the event to its targets; an event with none is not
%% routed and takes no Seq.
deliver({[], []}, _Event, _Metadata, Seq) ->
    Seq;
deliver({Handlers, PMs}, Event, Metadata, Seq) ->
    ok = route_to_handlers(Handlers, Event, Metadata),
    ok = route_to_pms(PMs, Event, Metadata),
    Seq + 1.

route_to_handlers([], _Event, _Metadata) -> ok;
route_to_handlers(Handlers, Event, Metadata) ->
    evoq_event_router:route_event(Event, Metadata, #{targets => Handlers}).

route_to_pms([], _Event, _Metadata) -> ok;
route_to_pms(PMs, Event, Metadata) -> evoq_pm_router:route_event(Event, Metadata, PMs).

%% @private Replay carries `replaying => true'; a new event carries no
%% such key, so metadata of live delivery is exactly what it always was.
-spec route_event_with_seq(evoq_event() | term(), non_neg_integer(), boolean()) ->
    non_neg_integer().
route_event_with_seq(E, Seq, Replaying) ->
    route_event_with_seq(E, Seq, Replaying, #{}).

route_event_with_seq(#evoq_event{event_type = EventType} = E, Seq, Replaying, Extra) ->
    case evoq_event_type_registry:get_handlers(EventType) of
        [] ->
            Seq;
        _Handlers ->
            {Event, Metadata0} = evoq_event_to_routable(E),
            Metadata = routed_metadata(Metadata0, Seq, Replaying, Extra),
            evoq_event_router:route_event(Event, Metadata),
            evoq_pm_router:route_event(Event, Metadata),
            Seq + 1
    end;
route_event_with_seq(_Other, Seq, _Replaying, _Extra) ->
    Seq.

%% @private Override version with the per-boot Seq, keep the original
%% stream version as stream_version, add Extra, mark replay.
routed_metadata(Metadata0, Seq, Replaying, Extra) ->
    StreamVersion = maps:get(version, Metadata0, 0),
    mark_replay(Replaying, maps:merge(Metadata0#{version => Seq,
                                                 stream_version => StreamVersion},
                                      Extra)).

mark_replay(true, Metadata) -> Metadata#{replaying => true};
mark_replay(false, Metadata) -> Metadata.

%% @private How far this node had consumed the store before it went down:
%% the persisted $all subscription's checkpoint, which this module acks
%% every ?ACK_EVERY_N_EVENTS events and on a clean stop. Everything below
%% it was already delivered to this node's handlers and process managers
%% in an earlier boot; everything from it on was appended while the node
%% was down and has never been delivered.
%%
%% No subscription yet means no earlier boot: nothing is replay. Any other
%% answer is also treated as "nothing is replay", which re-fires history
%% exactly as every boot did before this existed -- at-least-once rather
%% than losing what was appended while down -- and says so loudly.
%%
%% Limits, stated rather than hidden: acks are coalesced, so a CRASH (not
%% a clean stop, which flushes) re-fires up to ?ACK_EVERY_N_EVENTS - 1
%% events delivered after the last ack. Exactly-once would need a
%% checkpoint per handler, which this is not.
-spec seen_up_to(atom()) -> non_neg_integer().
seen_up_to(StoreId) ->
    seen_up_to(StoreId, evoq_subscriptions:get_checkpoint(StoreId, subscription_name(StoreId))).

seen_up_to(_StoreId, {ok, Checkpoint}) when is_integer(Checkpoint), Checkpoint >= 0 ->
    Checkpoint;
seen_up_to(_StoreId, {error, not_found}) ->
    0;
seen_up_to(StoreId, Other) ->
    logger:warning("[evoq] Could not read the persisted checkpoint for ~s (~p); "
                   "treating the whole store as new, so every handler and process "
                   "manager re-fires its history this boot", [StoreId, Other]),
    0.

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
