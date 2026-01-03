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
-export([notify/4]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    handler_module :: atom(),
    handler_state :: term(),
    event_types :: [binary()],
    consistency :: eventual | strong,
    checkpoint :: non_neg_integer()
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
    case HandlerModule:init(Config) of
        {ok, HandlerState} ->
            Consistency = maps:get(consistency, Opts, eventual),

            %% Register with event type registry
            lists:foreach(fun(EventType) ->
                evoq_event_type_registry:register(EventType, self())
            end, EventTypes),

            State = #state{
                handler_module = HandlerModule,
                handler_state = HandlerState,
                event_types = EventTypes,
                consistency = Consistency,
                checkpoint = 0
            },
            {ok, State};

        {error, Reason} ->
            {stop, Reason}
    end.

%% @private
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call({notify, EventType, Event, Metadata}, _From, State) ->
    case handle_event_internal(EventType, Event, Metadata, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {stop, Reason} ->
            %% Handler decided to stop
            {stop, Reason, {error, Reason}, State};
        {error, _Reason} = Error ->
            {reply, Error, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
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
