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

-optional_callbacks([on_error/4]).

%% API
-export([start_link/2, start_link/3]).
-export([get_event_types/1]).
-export([deliver/4]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%% An event currently being processed (or retried) by this handler.
-type inflight() :: none | {binary(), map(), map(), #evoq_failure_context{}}.

-record(state, {
    handler_module :: atom(),
    handler_state :: term(),
    event_types :: [binary()],
    consistency :: eventual | strong,
    checkpoint :: non_neg_integer(),
    %% Events delivered asynchronously (deliver/4) but not yet processed,
    %% kept in arrival order. The router hands events off without waiting,
    %% so a slow or retrying handler backs up here instead of stalling the
    %% router or any other handler.
    pending = queue:new() :: queue:queue({binary(), map(), map()}),
    %% The single event this handler is working on. While it is set, later
    %% pending events are held back, so per-handler order is preserved even
    %% across a retry.
    inflight = none :: inflight()
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
    %% Register with event type registry
    lists:foreach(fun register_self/1, EventTypes),
    State = #state{
        handler_module = HandlerModule,
        handler_state = HandlerState,
        event_types = EventTypes,
        consistency = Consistency,
        checkpoint = 0
    },
    {ok, State};
handle_init({error, Reason}, _HandlerModule, _EventTypes, _Opts) ->
    {stop, Reason}.

%% @private
register_self(EventType) ->
    evoq_event_type_registry:register(EventType, self()).

%% @private
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private Asynchronous delivery from the router. Enqueue and drive the
%% single-in-flight processing loop; a busy (retrying) handler just backs
%% events up in its own queue rather than blocking anyone.
handle_cast({deliver, EventType, Event, Metadata}, State) ->
    drive(enqueue(State, {EventType, Event, Metadata}));

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private A due retry: re-attempt whatever event is currently in flight.
%% The backoff elapsed as a timer, never as a sleep in this or any shared
%% process, so nothing was blocked while it ran.
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
