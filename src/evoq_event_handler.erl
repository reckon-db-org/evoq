%% @doc Event handler behavior for evoq.
%%
%% Event handlers subscribe to event types (NOT streams) and process
%% events as they are published. This is the key scalability improvement
%% over per-stream subscriptions.
%%
%% == Callbacks ==
%%
%% Required:
%% - interested_in() -> [binary()]
%%   Returns list of event types this handler processes
%%
%% - init(Config) -> {ok, State}
%%   Initialize handler state
%%
%% - handle_event(EventType, Event, Metadata, State) -> {ok, NewState} | {error, Reason}
%%   Process a single event
%%
%% Optional:
%% - on_error(Error, Event, FailureContext, State) -> error_action()
%%   Handle errors during event processing
%%
%% @author rgfaber
-module(evoq_event_handler).

-include("evoq.hrl").
-include("evoq_types.hrl").
-include("evoq_telemetry.hrl").

%% Required callbacks
-callback interested_in() -> [EventType :: binary()].
-callback init(Config :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.
-callback handle_event(EventType :: binary(), Event :: map(),
                       Metadata :: map(), State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

%% Optional callbacks
-callback on_error(Error :: term(), Event :: map(),
                   FailureContext :: #evoq_failure_context{}, State :: term()) ->
    evoq_error_handler:error_action().

%% Optional: a checkpointed handler declares its own start mode. `resume'
%% (default) continues from the durable checkpoint; `rebuild' replays the
%% whole store into fresh state, ignoring any stored checkpoint. Declared
%% per handler -- there is no global switch.
-callback start_mode() -> resume | rebuild.

-optional_callbacks([on_error/4, start_mode/0]).

%% API
-export([start_link/2, start_link/3]).
-export([get_event_types/1]).
-export([deliver/4]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1, handle_continue/2, handle_call/3, handle_cast/2,
         handle_info/2, terminate/2]).

%% An event currently being processed (or retried) by this handler.
-type inflight() :: none | {binary(), map(), map(), #evoq_failure_context{}}.

%% The global order key reckon-db sorts read_all_global by: {epoch_us,
%% stream_id, version}. Erlang term order over this tuple matches that
%% sort, so it is a total, restart-stable position -- unlike a per-stream
%% version, which is not globally comparable. `undefined' means nothing
%% has been processed yet (sorts below every real key).
-type order_key() :: undefined | {integer(), binary(), non_neg_integer()}.

-record(state, {
    handler_module :: atom(),
    handler_state :: term(),
    event_types :: [binary()],
    consistency :: eventual | strong,
    checkpoint :: non_neg_integer(),
    %% Events delivered asynchronously (deliver/4) but not yet processed,
    %% kept in arrival order. The router hands events off without waiting,
    %% so a slow or retrying handler backs up here instead of stalling the
    %% router or any other handler. (legacy mode only)
    pending = queue:new() :: queue:queue({binary(), map(), map()}),
    %% The single event this handler is working on. While it is set, later
    %% pending events are held back, so per-handler order is preserved even
    %% across a retry. (legacy mode only)
    inflight = none :: inflight(),
    %% == Checkpointed mode (store_id + checkpoint_store configured) ==
    %% When set, the handler is an ordered consumer whose single source is
    %% its own in-order read of the store from a durable checkpoint; the
    %% router's deliver/4 cast is only a wakeup. This is what lets a failed
    %% event be redelivered after a restart.
    checkpointed = false :: boolean(),
    store_id :: atom() | undefined,
    checkpoint_store :: module() | undefined,
    start_mode = resume :: resume | rebuild,
    %% In-memory next global scan position (count of events consumed from
    %% read_all_global). The durable checkpoint trails this at the last
    %% committed interested event; never leads it (fail-closed).
    offset = 0 :: non_neg_integer(),
    %% Order key of the last processed interested event (for dedup).
    ckpt_key = undefined :: order_key(),
    %% A failed interested event awaiting retry: its context, carried
    %% across attempts. The offset still points AT it, so a retry re-reads
    %% it from the store. `none' when not retrying.
    retry = none :: none | #evoq_failure_context{}
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start an event handler.
-spec start_link(atom(), map()) -> {ok, pid()} | {error, term()}.
start_link(HandlerModule, Config) ->
    start_link(HandlerModule, Config, #{}).

%% @doc Start an event handler with options.
-spec start_link(atom(), map(), map()) -> {ok, pid()} | {error, term()}.
start_link(HandlerModule, Config, Opts) ->
    gen_server:start_link(?MODULE, {HandlerModule, Config, Opts}, []).

%% @doc Get event types this handler is interested in.
-spec get_event_types(pid()) -> [binary()].
get_event_types(Pid) ->
    gen_server:call(Pid, get_event_types).

%% @doc Hand an event to the handler without waiting.
%%
%% Delivery is a cast: it never blocks the caller and never fails on a
%% dead handler. The handler enqueues the event and processes it in
%% arrival order in its own process, so a slow, failing or retrying
%% handler delays only itself. This is the router's delivery path.
-spec deliver(pid(), binary(), map(), map()) -> ok.
deliver(Pid, EventType, Event, Metadata) ->
    gen_server:cast(Pid, {deliver, EventType, Event, Metadata}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({HandlerModule, Config, Opts}) ->
    %% Get event types the handler is interested in
    EventTypes = HandlerModule:interested_in(),

    %% Initialize the handler
    handle_init(HandlerModule:init(Config), HandlerModule, EventTypes, Opts).

%% @private
handle_init({ok, HandlerState}, HandlerModule, EventTypes, Opts) ->
    Consistency = maps:get(consistency, Opts, eventual),
    StoreId = maps:get(store_id, Opts, undefined),
    CheckpointStore = maps:get(checkpoint_store, Opts, undefined),
    %% Register with event type registry
    lists:foreach(fun register_self/1, EventTypes),
    Base = #state{
        handler_module = HandlerModule,
        handler_state = HandlerState,
        event_types = EventTypes,
        consistency = Consistency,
        checkpoint = 0,
        store_id = StoreId,
        checkpoint_store = CheckpointStore
    },
    start_mode_init(checkpointed(StoreId, CheckpointStore), Base);
handle_init({error, Reason}, _HandlerModule, _EventTypes, _Opts) ->
    {stop, Reason}.

%% @private A handler is a checkpointed ordered consumer only when both a
%% store to read and a durable checkpoint store are configured; otherwise
%% it is a plain (legacy) push consumer.
checkpointed(StoreId, CheckpointStore) ->
    StoreId =/= undefined andalso CheckpointStore =/= undefined.

%% @private Legacy push consumer: ready immediately.
start_mode_init(false, State) ->
    {ok, State};
%% Checkpointed consumer: load its durable position (or reset for a
%% rebuild) and begin catch-up before handling its first wakeup.
start_mode_init(true, #state{handler_module = HandlerModule} = State) ->
    Mode = start_mode(HandlerModule),
    {Offset, Key} = initial_position(Mode, State),
    {ok, State#state{checkpointed = true, start_mode = Mode,
                     offset = Offset, ckpt_key = Key},
     {continue, catch_up}}.

%% @private resume reads from the durable checkpoint; rebuild ignores it
%% and replays the whole store from the start into fresh state.
initial_position(rebuild, _State) ->
    {0, undefined};
initial_position(resume, #state{handler_module = HandlerModule,
                                checkpoint_store = CheckpointStore}) ->
    load_position(CheckpointStore:load(HandlerModule)).

load_position({ok, {Offset, Key}}) -> {Offset, Key};
load_position(_) -> {0, undefined}.

%% @private
start_mode(HandlerModule) ->
    resolve_start_mode(erlang:function_exported(HandlerModule, start_mode, 0),
                       HandlerModule).

resolve_start_mode(true, HandlerModule) -> HandlerModule:start_mode();
resolve_start_mode(false, _HandlerModule) -> resume.

%% @private
register_self(EventType) ->
    evoq_event_type_registry:register(EventType, self()).

%% @private Checkpointed consumers begin by draining the store from their
%% durable position, in global order, before their first wakeup.
handle_continue(catch_up, State) ->
    catch_up(State).

%% @private
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private Asynchronous delivery from the router.
%%
%% Checkpointed mode: the cast is only a wakeup. The event's payload is
%% NOT processed from the cast -- the handler re-reads the store in order
%% from its checkpoint, so the store is the single source and a live event
%% arriving ahead of catch-up can never make the checkpoint jump past
%% events not yet processed.
%%
%% Legacy mode: enqueue and drive the single-in-flight loop.
handle_cast({deliver, _EventType, _Event, _Metadata}, #state{checkpointed = true} = State) ->
    wake(State);
handle_cast({deliver, EventType, Event, Metadata}, State) ->
    drive(enqueue(State, {EventType, Event, Metadata}));

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private A due retry.
%%
%% Checkpointed mode: the failed event's offset was never advanced, so
%% resuming catch-up re-reads and re-attempts it (with its carried
%% context) before anything after it -- order preserved.
%%
%% Legacy mode: re-attempt whatever event is currently in flight.
handle_info(retry_head, #state{checkpointed = true} = State) ->
    catch_up(State);
handle_info(retry_head, State) ->
    retry_inflight(State);

handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, #state{event_types = EventTypes}) ->
    %% Unregister from event type registry
    lists:foreach(fun(EventType) ->
        evoq_event_type_registry:unregister(EventType, self())
    end, EventTypes),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%%--------------------------------------------------------------------
%% Asynchronous delivery driver (the router's path)
%%--------------------------------------------------------------------
%% One event is processed at a time, in arrival order. A retry keeps the
%% failed event in flight and defers the rest of the queue, so per-handler
%% order holds across retries. Nothing here blocks: a backoff is a timer,
%% not a sleep.

%% @private Append an event to the pending queue.
enqueue(#state{pending = Q} = State, Item) ->
    State#state{pending = queue:in(Item, Q)}.

%% @private Start the next event if the handler is idle; otherwise leave
%% it queued behind the in-flight one.
-spec drive(#state{}) -> {noreply, #state{}} | {stop, term(), #state{}}.
drive(#state{inflight = none, pending = Q} = State) ->
    drive_next(queue:out(Q), State);
drive(State) ->
    {noreply, State}.

drive_next({empty, _Q}, State) ->
    {noreply, State};
drive_next({{value, {EventType, Event, Metadata}}, Q1}, State) ->
    Context = new_failure_context(State#state.handler_module, Event),
    run_inflight(State#state{pending = Q1,
                             inflight = {EventType, Event, Metadata, Context}}).

%% @private Attempt the in-flight event once and act on the result.
run_inflight(#state{inflight = {EventType, Event, Metadata, Context}} = State) ->
    dispatch_action(attempt_event(EventType, Event, Metadata, Context, State), State).

dispatch_action({done, NewState}, _State) ->
    drive(NewState#state{inflight = none});
dispatch_action({retry, DelayMs, Context1},
                #state{inflight = {EventType, Event, Metadata, _}} = State) ->
    _ = erlang:send_after(DelayMs, self(), retry_head),
    {noreply, State#state{inflight = {EventType, Event, Metadata, Context1}}};
dispatch_action({stop, Reason}, State) ->
    {stop, Reason, State}.

%% @private A due retry re-attempts the in-flight event. A stray timer
%% (event already resolved) is a harmless no-op.
retry_inflight(#state{inflight = none} = State) ->
    {noreply, State};
retry_inflight(State) ->
    run_inflight(State).

%%--------------------------------------------------------------------
%% Checkpointed ordered consumer (store_id + checkpoint_store configured)
%%--------------------------------------------------------------------
%% The store, read in global {epoch_us, stream_id, version} order from a
%% durable checkpoint, is the single source. A deliver/4 cast is only a
%% wakeup. The checkpoint advances one interested event at a time and is
%% persisted before the next event is taken, so it can never pass an event
%% this handler has not processed, and a restart resumes exactly where it
%% left off.

-define(CATCH_UP_BATCH, 1000).

%% @private A wakeup: drain any new events from the store. Harmless if
%% there is nothing new (the read returns empty).
wake(State) ->
    catch_up(State).

%% @private Read a batch from the store at the current offset and process
%% it in order. Recurses until the store is drained.
catch_up(#state{store_id = StoreId, offset = Offset} = State) ->
    handle_batch(evoq_event_store:read_all_global(StoreId, Offset, ?CATCH_UP_BATCH),
                 State).

%% A read error is not fatal: stay at the current durable position and try
%% again on the next wakeup (fail-closed -- the offset never advances past
%% events that were not read and processed).
handle_batch({error, Reason}, #state{store_id = StoreId, offset = Offset} = State) ->
    logger:warning("[evoq] handler ~p catch-up read failed for ~p at offset ~b: ~p",
                   [State#state.handler_module, StoreId, Offset, Reason]),
    {noreply, State};
handle_batch({ok, []}, State) ->
    {noreply, State};
handle_batch({ok, Events}, State) ->
    process_batch(Events, length(Events) < ?CATCH_UP_BATCH, State).

%% @private Fold over a batch in order. A short batch means the store edge
%% was reached, so there is no need to read again once it is drained.
process_batch([], _LastBatch = true, State) ->
    {noreply, State};
process_batch([], _LastBatch = false, State) ->
    catch_up(State);
process_batch([Event | Rest], LastBatch, State) ->
    consume_event(interested(Event, State), Event, Rest, LastBatch, State).

%% @private A non-interested event only advances the scan offset (in
%% memory -- re-scanning it after a restart is cheap and harmless, so it
%% need not be persisted).
consume_event(false, _Event, Rest, LastBatch, #state{offset = Offset} = State) ->
    process_batch(Rest, LastBatch, State#state{offset = Offset + 1});
consume_event(true, Event, Rest, LastBatch, State) ->
    {EventType, EventMap, Metadata} = to_routable(Event),
    Context = attempt_context(State, EventMap),
    step_after(attempt_event(EventType, EventMap, Metadata, Context, State),
               order_key(Event), Rest, LastBatch, State).

%% @private Act on one interested event's outcome.
%% done: persist the advanced checkpoint BEFORE taking the next event; if
%%   the persist fails the handler stops taking events (fail-closed).
%% retry: leave the offset AT this event and schedule a timer; on the
%%   timer catch-up re-reads and re-attempts it, in order.
%% stop: stop the process.
step_after({done, NewState}, Key, Rest, LastBatch, #state{offset = Offset} = State) ->
    Advanced = NewState#state{offset = Offset + 1, ckpt_key = Key, retry = none},
    persisted(persist_checkpoint(Advanced), Rest, LastBatch, Advanced, State);
step_after({retry, DelayMs, Context1}, _Key, _Rest, _LastBatch, State) ->
    _ = erlang:send_after(DelayMs, self(), retry_head),
    {noreply, State#state{retry = Context1}};
step_after({stop, Reason}, _Key, _Rest, _LastBatch, State) ->
    {stop, Reason, State}.

%% @private Only continue once the advanced checkpoint is durable. If the
%% checkpoint store is unavailable, do NOT process further events: stay at
%% the last durable position (the in-memory checkpoint never leads it) and
%% retry on the next wakeup.
persisted(ok, Rest, LastBatch, Advanced, _Before) ->
    process_batch(Rest, LastBatch, Advanced);
persisted({error, Reason}, _Rest, _LastBatch, _Advanced, Before) ->
    logger:warning("[evoq] handler ~p checkpoint persist failed at offset ~b: ~p "
                   "-- pausing until it recovers",
                   [Before#state.handler_module, Before#state.offset, Reason]),
    {noreply, Before}.

%% @private Persist {offset, key} durably. Normalised to ok | {error, _}.
persist_checkpoint(#state{handler_module = HandlerModule,
                          checkpoint_store = CheckpointStore,
                          offset = Offset, ckpt_key = Key}) ->
    normalize_persist(CheckpointStore:save(HandlerModule, {Offset, Key})).

normalize_persist(ok) -> ok;
normalize_persist({error, _} = Error) -> Error;
normalize_persist(Other) -> {error, {unexpected_persist_result, Other}}.

%% @private The context for the current attempt: the carried one if this
%% is a retry (so the attempt number keeps climbing toward the dead-letter
%% limit), otherwise a fresh one for this event.
attempt_context(#state{retry = none, handler_module = HandlerModule}, EventMap) ->
    new_failure_context(HandlerModule, EventMap);
attempt_context(#state{retry = Context}, _EventMap) ->
    Context.

%% @private Is this event one of the handler's types?
interested(Event, #state{event_types = Types}) ->
    lists:member(event_type_of(Event), Types).

event_type_of(#evoq_event{event_type = Type}) -> Type.

%% @private The global order key {epoch_us, stream_id, version}.
order_key(#evoq_event{epoch_us = EpochUs, stream_id = StreamId, version = Version}) ->
    {EpochUs, StreamId, Version}.

%% @private Convert the stored record to the {EventType, Event, Metadata}
%% the callback expects (same shape the router delivers).
to_routable(#evoq_event{event_type = EventType} = Event) ->
    {EventMap, Metadata} = evoq_store_subscription:evoq_event_to_routable(Event),
    {EventType, EventMap, Metadata}.

%%--------------------------------------------------------------------
%% Single-attempt core
%%--------------------------------------------------------------------

%% @private One attempt at an event. Returns the next step for the driver
%% to carry out; it never loops, sleeps, or blocks itself.
-spec attempt_event(binary(), map(), map(), #evoq_failure_context{}, #state{}) ->
    {done, #state{}} | {retry, non_neg_integer(), #evoq_failure_context{}} |
    {stop, term()}.
attempt_event(EventType, Event, Metadata, Context, State) ->
    #state{handler_module = HandlerModule, handler_state = HandlerState} = State,
    StartTime = erlang:system_time(microsecond),
    telemetry:execute(?TELEMETRY_HANDLER_EVENT_START,
                      #{system_time => StartTime},
                      #{handler => HandlerModule, event_type => EventType,
                        attempt => Context#evoq_failure_context.attempt_number}),
    Outcome = run_callback(HandlerModule, EventType, Event, Metadata, HandlerState),
    handle_result(Outcome, EventType, Event, Metadata, Context, State, StartTime).

%% @private Invoke the handler callback, converting a raise OR an
%% unexpected return into the same {error, Reason, Stacktrace} the error
%% path already handles -- so a throwing or misbehaving handler goes
%% through on_error/retry/dead-letter instead of crashing the process and
%% losing its queue and mailbox. A bad return matching neither {ok, _} nor
%% {error, _} would otherwise raise try_clause in the `of' section, which
%% the `catch' does NOT cover, so it needs its own clause here. A returned
%% error carries an empty stacktrace; a caught raise carries a sanitized
%% one (argument lists stripped, so event data never rides a stack frame
%% into a dead letter, on_error, or a log).
-spec run_callback(atom(), binary(), map(), map(), term()) ->
    {ok, term()} | {error, term(), list()}.
run_callback(HandlerModule, EventType, Event, Metadata, HandlerState) ->
    try HandlerModule:handle_event(EventType, Event, Metadata, HandlerState) of
        {ok, NewHandlerState} -> {ok, NewHandlerState};
        {error, Reason} -> {error, Reason, []};
        Other -> {error, {bad_return, return_shape(Other)}, []}
    catch
        Class:Reason:Stacktrace -> {error, {Class, Reason}, sanitize_stacktrace(Stacktrace)}
    end.

%% @private Reduce a bad return to its shape -- its tag (and arity for a
%% tagged tuple) or its term kind -- so an event's data or the handler's
%% state, which a return term can carry, never reaches a dead letter,
%% on_error, or a log. Atoms are kept whole (they carry no payload).
return_shape(Atom) when is_atom(Atom) -> Atom;
return_shape(Tuple) when is_tuple(Tuple), tuple_size(Tuple) >= 1,
                         is_atom(element(1, Tuple)) ->
    {element(1, Tuple), tuple_size(Tuple)};
return_shape(Tuple) when is_tuple(Tuple) -> {tuple, tuple_size(Tuple)};
return_shape(List) when is_list(List) -> list;
return_shape(Map) when is_map(Map) -> map;
return_shape(Bin) when is_binary(Bin) -> binary;
return_shape(Int) when is_integer(Int) -> integer;
return_shape(Float) when is_float(Float) -> float;
return_shape(Pid) when is_pid(Pid) -> pid;
return_shape(_) -> other.

%% @private Replace each frame's argument list with its arity, so captured
%% stack frames carry no event payload into anything downstream.
sanitize_stacktrace(Stacktrace) ->
    [sanitize_frame(Frame) || Frame <- Stacktrace].

sanitize_frame({Module, Function, Args, Location}) when is_list(Args) ->
    {Module, Function, length(Args), Location};
sanitize_frame(Frame) ->
    Frame.

handle_result({ok, NewHandlerState}, EventType, _Event, Metadata, _Context, State, StartTime) ->
    telemetry:execute(?TELEMETRY_HANDLER_EVENT_STOP,
                      #{duration => erlang:system_time(microsecond) - StartTime},
                      #{handler => State#state.handler_module, event_type => EventType}),
    {done, State#state{handler_state = NewHandlerState,
                       checkpoint = advance(Metadata, State)}};
handle_result({error, Reason, Stacktrace}, EventType, Event, Metadata, Context, State, StartTime) ->
    #state{handler_module = HandlerModule, handler_state = HandlerState} = State,
    telemetry:execute(?TELEMETRY_HANDLER_EVENT_EXCEPTION,
                      #{duration => erlang:system_time(microsecond) - StartTime},
                      #{handler => HandlerModule, event_type => EventType, error => Reason}),
    Context1 = Context#evoq_failure_context{
        error = Reason, last_failure_at = erlang:system_time(millisecond),
        stacktrace = Stacktrace},
    Action = evoq_error_handler:handle_error(
        HandlerModule, Reason, Event, Context1, HandlerState),
    map_action(Action, Event, Metadata, Context1, State).

%% @private Translate the error handler's decision into a driver step.
map_action(retry, _Event, _Metadata, Context, _State) ->
    {retry, 0, increment_attempt(Context)};
map_action({retry, DelayMs}, _Event, _Metadata, Context, _State) ->
    {retry, DelayMs, increment_attempt(Context)};
map_action(skip, _Event, Metadata, _Context, State) ->
    {done, State#state{checkpoint = advance(Metadata, State)}};
map_action({dead_letter, Reason}, Event, Metadata, Context, State) ->
    _ = evoq_dead_letter:store(Event, State#state.handler_module, Context, Reason),
    {done, State#state{checkpoint = advance(Metadata, State)}};
map_action(stop, _Event, _Metadata, Context, _State) ->
    {stop, {handler_stopped, Context#evoq_failure_context.error}}.

%% @private Next checkpoint from event metadata, or the current one.
advance(Metadata, #state{checkpoint = Checkpoint}) ->
    maps:get(version, Metadata, Checkpoint).

%% @private
new_failure_context(HandlerModule, Event) ->
    Now = erlang:system_time(millisecond),
    #evoq_failure_context{
        handler_module = HandlerModule,
        event = Event,
        error = undefined,
        attempt_number = 1,
        first_failure_at = Now,
        last_failure_at = Now,
        stacktrace = []
    }.

%% @private
increment_attempt(#evoq_failure_context{attempt_number = N} = Ctx) ->
    Ctx#evoq_failure_context{attempt_number = N + 1}.
