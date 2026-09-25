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
%% - replay_policy() -> skip | deliver
%%   What to do with REPLAY: events this node had already consumed before
%%   it restarted, which evoq_store_subscription hands out again on every
%%   boot with `replaying => true' in the metadata. `skip' for a handler
%%   with side effects (publishing, sending, dispatching), which would
%%   otherwise repeat every one of them on every restart. `deliver' for a
%%   handler rebuilding in-memory state from history.
%%
%%   Not declaring it delivers, as before this callback existed, and logs
%%   one warning per boot naming the handler the first time it is handed
%%   replay: a handler with side effects and no policy is the one to find.
%%
%% - handle_info(Info, State) -> {noreply, NewState} | {stop, Reason, NewState}
%%   Any other message the handler process receives, most usefully one it
%%   scheduled to itself from handle_event/4 (a retry via send_after).
%%   Same shape as gen_server's. A handler without it that is sent a
%%   message logs a warning naming itself and the message.
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

-callback replay_policy() -> skip | deliver.

-callback handle_info(Info :: term(), State :: term()) ->
    {noreply, NewState :: term()} | {stop, Reason :: term(), NewState :: term()}.

-optional_callbacks([on_error/4, replay_policy/0, handle_info/2]).

%% API
-export([start_link/2, start_link/3]).
-export([get_event_types/1]).
-export([notify/4]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    handler_module :: atom(),
    handler_state :: term(),
    event_types :: [binary()],
    consistency :: eventual | strong,
    checkpoint :: non_neg_integer(),
    %% Whether this boot has already warned that the handler receives
    %% replay without declaring replay_policy/0. Once per boot, not once
    %% per event: a store's whole history arrives as replay.
    replay_warned = false :: boolean()
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

%% @doc Notify handler of an event.
-spec notify(pid(), binary(), map(), map()) -> ok | {error, term()}.
notify(Pid, EventType, Event, Metadata) ->
    gen_server:call(Pid, {notify, EventType, Event, Metadata}, infinity).

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
    ok = evoq_event_type_registry:register_all(EventTypes, self()),
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
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call({notify, EventType, Event, Metadata}, _From,
            #state{handler_module = HandlerModule, replay_warned = Warned} = State) ->
    {Action, Warned1} = replay_gate(HandlerModule, Metadata, Warned),
    notify_reply(Action, EventType, Event, Metadata,
                 State#state{replay_warned = Warned1});

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private A skipped replay still moves the checkpoint: the event is
%% consumed, the handler just declared it must not react to it again.
notify_reply(skip, _EventType, _Event, Metadata, #state{checkpoint = Checkpoint} = State) ->
    {reply, ok, State#state{checkpoint = maps:get(version, Metadata, Checkpoint)}};
notify_reply(deliver, EventType, Event, Metadata, State) ->
    case handle_event_internal(EventType, Event, Metadata, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {stop, Reason} ->
            %% Handler decided to stop
            {stop, Reason, {error, Reason}, State};
        {error, _Reason} = Error ->
            {reply, Error, State}
    end.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private Everything else goes to the handler module. This dropped every
%% message, so a handler's own scheduled retry never ran and nothing said.
handle_info(Info, #state{handler_module = HandlerModule} = State) ->
    forward_info(erlang:function_exported(HandlerModule, handle_info, 2), Info, State).

forward_info(true, Info, #state{handler_module = HandlerModule,
                                handler_state = HandlerState} = State) ->
    info_result(HandlerModule:handle_info(Info, HandlerState), HandlerModule, State);
forward_info(false, Info, #state{handler_module = HandlerModule} = State) ->
    logger:warning(#{what => evoq_handler_has_no_handle_info,
                     handler => HandlerModule,
                     message => Info}),
    {noreply, State}.

info_result({noreply, NewHandlerState}, _HandlerModule, State) ->
    {noreply, State#state{handler_state = NewHandlerState}};
info_result({stop, Reason, NewHandlerState}, _HandlerModule, State) ->
    {stop, Reason, State#state{handler_state = NewHandlerState}};
info_result(Other, HandlerModule, _State) ->
    error({bad_handle_info_return, HandlerModule, Other}).

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

%% @private Decides what a handler module gets of one event: `deliver' or
%% `skip'. Only replay (`replaying => true' in Metadata) can be skipped,
%% and only by a module declaring `replay_policy() -> skip'. Warned says
%% whether this boot already warned about Module receiving replay with no
%% policy; the returned boolean is the new value, kept in the handler's
%% state for the rest of the boot.
-spec replay_gate(module(), map(), boolean()) -> {deliver | skip, boolean()}.
replay_gate(Module, Metadata, Warned) ->
    gate(maps:get(replaying, Metadata, false), Module, Warned).

%% Live events never look the policy up: they are the common case.
gate(false, _Module, Warned) -> {deliver, Warned};
gate(true, Module, Warned) -> gate_replay(replay_policy_of(Module), Module, Warned).

gate_replay(skip, _Module, Warned) -> {skip, Warned};
gate_replay(deliver, _Module, Warned) -> {deliver, Warned};
gate_replay(undeclared, _Module, true) -> {deliver, true};
gate_replay(undeclared, Module, false) ->
    logger:warning(#{what => evoq_handler_received_replay_without_policy,
                     handler => Module,
                     advice => <<"this handler is receiving events the node already "
                                 "consumed before it restarted. Declare "
                                 "replay_policy() -> skip if it has side effects, "
                                 "or -> deliver to keep receiving them and silence "
                                 "this warning.">>}),
    {deliver, true}.

replay_policy_of(Module) ->
    _ = code:ensure_loaded(Module),
    replay_policy_of(erlang:function_exported(Module, replay_policy, 0), Module).

replay_policy_of(false, _Module) -> undeclared;
replay_policy_of(true, Module) -> valid_replay_policy(Module:replay_policy(), Module).

%% Anything but skip or deliver is a bug in the handler, and guessing
%% either way would hide it: one repeats side effects, the other loses
%% history.
valid_replay_policy(skip, _Module) -> skip;
valid_replay_policy(deliver, _Module) -> deliver;
valid_replay_policy(Other, Module) -> error({bad_replay_policy, Module, Other}).

%% @private
handle_event_internal(EventType, Event, Metadata, State) ->
    FailureContext = #evoq_failure_context{
        handler_module = State#state.handler_module,
        event = Event,
        error = undefined,
        attempt_number = 1,
        first_failure_at = erlang:system_time(millisecond),
        last_failure_at = erlang:system_time(millisecond),
        stacktrace = []
    },
    handle_event_with_retry(EventType, Event, Metadata, State, FailureContext).

%% @private
handle_event_with_retry(EventType, Event, Metadata, State, FailureContext) ->
    #state{
        handler_module = HandlerModule,
        handler_state = HandlerState,
        checkpoint = Checkpoint
    } = State,

    StartTime = erlang:system_time(microsecond),

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_HANDLER_EVENT_START, #{
        system_time => StartTime
    }, #{
        handler => HandlerModule,
        event_type => EventType,
        attempt => FailureContext#evoq_failure_context.attempt_number
    }),

    %% Call the handler
    case HandlerModule:handle_event(EventType, Event, Metadata, HandlerState) of
        {ok, NewHandlerState} ->
            Duration = erlang:system_time(microsecond) - StartTime,

            %% Emit success telemetry
            telemetry:execute(?TELEMETRY_HANDLER_EVENT_STOP, #{
                duration => Duration
            }, #{
                handler => HandlerModule,
                event_type => EventType
            }),

            %% Update checkpoint from event metadata
            NewCheckpoint = maps:get(version, Metadata, Checkpoint),

            NewState = State#state{
                handler_state = NewHandlerState,
                checkpoint = NewCheckpoint
            },
            {ok, NewState};

        {error, Reason} ->
            Duration = erlang:system_time(microsecond) - StartTime,

            %% Emit failure telemetry
            telemetry:execute(?TELEMETRY_HANDLER_EVENT_EXCEPTION, #{
                duration => Duration
            }, #{
                handler => HandlerModule,
                event_type => EventType,
                error => Reason
            }),

            %% Update failure context
            UpdatedContext = FailureContext#evoq_failure_context{
                error = Reason,
                last_failure_at = erlang:system_time(millisecond)
            },

            %% Get error action from handler or use default
            Action = evoq_error_handler:handle_error(
                HandlerModule, Reason, Event, UpdatedContext, HandlerState
            ),

            %% Execute the action
            execute_error_action(Action, EventType, Event, Metadata, State, UpdatedContext)
    end.

%% @private
%% Execute error action based on handler's decision
execute_error_action(retry, EventType, Event, Metadata, State, FailureContext) ->
    %% Retry immediately
    NewContext = increment_attempt(FailureContext),
    handle_event_with_retry(EventType, Event, Metadata, State, NewContext);

execute_error_action({retry, DelayMs}, EventType, Event, Metadata, State, FailureContext) ->
    %% Retry after delay
    timer:sleep(DelayMs),
    NewContext = increment_attempt(FailureContext),
    handle_event_with_retry(EventType, Event, Metadata, State, NewContext);

execute_error_action(skip, _EventType, _Event, Metadata, State, _FailureContext) ->
    %% Skip this event, update checkpoint and continue
    #state{checkpoint = Checkpoint} = State,
    NewCheckpoint = maps:get(version, Metadata, Checkpoint),
    {ok, State#state{checkpoint = NewCheckpoint}};

execute_error_action(stop, _EventType, _Event, _Metadata, _State, FailureContext) ->
    %% Stop the handler - return error to trigger gen_server stop
    {stop, {handler_stopped, FailureContext#evoq_failure_context.error}};

execute_error_action({dead_letter, Reason}, _EventType, Event, Metadata, State, FailureContext) ->
    %% Send to dead letter queue and continue
    #state{handler_module = HandlerModule, checkpoint = Checkpoint} = State,

    %% Store in dead letter
    _ = evoq_dead_letter:store(Event, HandlerModule, FailureContext, Reason),

    %% Update checkpoint and continue
    NewCheckpoint = maps:get(version, Metadata, Checkpoint),
    {ok, State#state{checkpoint = NewCheckpoint}}.

%% @private
increment_attempt(#evoq_failure_context{attempt_number = N} = Ctx) ->
    Ctx#evoq_failure_context{attempt_number = N + 1}.
