%% @doc Projection behavior for evoq.
%%
%% Projections transform events into read model updates.
%% They subscribe to event types and maintain query-optimized views.
%%
%% == Design Principles ==
%%
%% - Projections do all calculations (events -> read model)
%% - Read models are simple key-value lookups (no joins)
%% - Projections are idempotent (can be replayed safely)
%% - Checkpoints track progress for resume after restart
%%
%% == Callbacks ==
%%
%% Required:
%% - interested_in() -> [binary()]
%%   Event types this projection handles
%%
%% - init(Config) -> {ok, State, ReadModel}
%%   Initialize projection with read model
%%
%% - project(Event, Metadata, State, ReadModel) ->
%%     {ok, NewState, NewReadModel} | {error, Reason}
%%   Transform event into read model updates
%%
%% Optional:
%% - on_error(Error, Event, FailureContext, State) -> error_action()
%%   Handle projection errors
%%
%% == Example ==
%%
%% ```
%% -module(order_summary_projection).
%% -behaviour(evoq_projection).
%%
%% interested_in() -> [<<"OrderPlaced">>, <<"OrderShipped">>].
%%
%% init(_Config) ->
%%     {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
%%     {ok, #{}, RM}.
%%
%% project(#{event_type := <<"OrderPlaced">>, data := Data}, Meta, State, RM) ->
%%     OrderId = maps:get(order_id, Data),
%%     Summary = #{status => placed, items => maps:get(items, Data, [])},
%%     {ok, RM2} = evoq_read_model:put(OrderId, Summary, RM),
%%     {ok, State, RM2}.
%% '''
%%
%% @author rgfaber
-module(evoq_projection).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% Rate-limit the dropped-event warning to at most one per this window.
-define(DROP_LOG_WINDOW_MS, 60000).

%% Required callbacks
-callback interested_in() -> [EventType :: binary()].

-callback init(Config :: map()) ->
    {ok, State :: term(), ReadModel :: evoq_read_model:read_model()} |
    {error, Reason :: term()}.

-callback project(Event :: map(), Metadata :: map(),
                  State :: term(), ReadModel :: evoq_read_model:read_model()) ->
    {ok, NewState :: term(), NewReadModel :: evoq_read_model:read_model()} |
    {skip, State :: term(), ReadModel :: evoq_read_model:read_model()} |
    {error, Reason :: term()}.

%% Optional callbacks
-callback on_error(Error :: term(), Event :: map(),
                   FailureContext :: #evoq_failure_context{}, State :: term()) ->
    evoq_error_handler:error_action().

-optional_callbacks([on_error/4]).

%% API
-export([start_link/2, start_link/3]).
-export([get_event_types/1]).
-export([get_checkpoint/1]).
-export([get_read_model/1]).
-export([rebuild/1, rebuild/2]).
-export([notify/4]).

%% gen_server callbacks
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-record(state, {
    projection_module :: atom(),
    projection_state :: term(),
    read_model :: evoq_read_model:read_model(),
    event_types :: [binary()],
    checkpoint :: non_neg_integer(),
    checkpoint_store :: atom() | undefined,
    store_id :: atom() | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a projection.
-spec start_link(atom(), map()) -> {ok, pid()} | {error, term()}.
start_link(ProjectionModule, Config) ->
    start_link(ProjectionModule, Config, #{}).

%% @doc Start a projection with options.
%% Options:
%% - store_id: Event store to replay from (overrides app env)
%% - checkpoint_store: Module for persistent checkpoint storage
%% - start_from: origin | latest | {position, N}
-spec start_link(atom(), map(), map()) -> {ok, pid()} | {error, term()}.
start_link(ProjectionModule, Config, Opts) ->
    gen_server:start_link(?MODULE, {ProjectionModule, Config, Opts}, []).

%% @doc Get event types this projection handles.
-spec get_event_types(pid()) -> [binary()].
get_event_types(Pid) ->
    gen_server:call(Pid, get_event_types).

%% @doc Get the current checkpoint position.
-spec get_checkpoint(pid()) -> non_neg_integer().
get_checkpoint(Pid) ->
    gen_server:call(Pid, get_checkpoint).

%% @doc Get the read model instance.
-spec get_read_model(pid()) -> evoq_read_model:read_model().
get_read_model(Pid) ->
    gen_server:call(Pid, get_read_model).

%% @doc Rebuild the projection from scratch.
%% Clears the read model and replays all events.
-spec rebuild(pid()) -> ok | {error, term()}.
rebuild(Pid) ->
    rebuild(Pid, #{}).

%% @doc Rebuild with options.
-spec rebuild(pid(), map()) -> ok | {error, term()}.
rebuild(Pid, Opts) ->
    gen_server:call(Pid, {rebuild, Opts}, infinity).

%% @doc Notify projection of an event.
-spec notify(pid(), binary(), map(), map()) -> ok | {error, term()}.
notify(Pid, EventType, Event, Metadata) ->
    gen_server:call(Pid, {notify, EventType, Event, Metadata}, infinity).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({ProjectionModule, Config, Opts}) ->
    %% Get event types
    EventTypes = ProjectionModule:interested_in(),

    %% Initialize projection
    case ProjectionModule:init(Config) of
        {ok, ProjectionState, ReadModel} ->
            CheckpointStore = maps:get(checkpoint_store, Opts, undefined),
            OverrideStoreId = maps:get(store_id, Opts, undefined),

            %% Load checkpoint if store available
            Checkpoint = load_checkpoint(ProjectionModule, CheckpointStore),

            %% Register with event type registry
            lists:foreach(fun register_self/1, EventTypes),

            %% Emit start telemetry
            telemetry:execute(?TELEMETRY_PROJECTION_START, #{}, #{
                projection => ProjectionModule
            }),

            State = #state{
                projection_module = ProjectionModule,
                projection_state = ProjectionState,
                read_model = ReadModel,
                event_types = EventTypes,
                checkpoint = Checkpoint,
                checkpoint_store = CheckpointStore,
                store_id = OverrideStoreId
            },
            {ok, State};

        {error, Reason} ->
            {stop, Reason}
    end.

%% @private
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call(get_checkpoint, _From, #state{checkpoint = Checkpoint} = State) ->
    {reply, Checkpoint, State};

handle_call(get_read_model, _From, #state{read_model = RM} = State) ->
    {reply, RM, State};

handle_call({rebuild, _Opts}, _From, State) ->
    case do_rebuild(State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call({notify, EventType, Event, Metadata}, _From, State) ->
    case handle_event_internal(EventType, Event, Metadata, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {error, Reason} ->
            {reply, {error, Reason}, State}
    end;

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private Asynchronous delivery from the event router. A projection
%% registers its pid in the same event-type registry as a handler, so it
%% receives the router's {deliver, ...} cast. Processing is synchronous
%% within the cast and the gen_server serializes casts, so events are
%% applied one at a time in arrival order (a projection has no retry, so
%% no explicit queue is needed -- the mailbox is the queue). On a project
%% error the checkpoint is not advanced (the event is left for redelivery
%% by a later catch-up), matching the pre-async behaviour.
handle_cast({deliver, EventType, Event, Metadata}, State) ->
    {noreply, apply_delivered(handle_event_internal(EventType, Event, Metadata, State), State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
apply_delivered({ok, NewState}, _State) -> NewState;
apply_delivered({error, _Reason}, State) -> State.

%% @private
terminate(_Reason, #state{
    projection_module = ProjectionModule,
    event_types = EventTypes
}) ->
    %% Unregister from event type registry
    lists:foreach(fun(EventType) ->
        evoq_event_type_registry:unregister(EventType, self())
    end, EventTypes),

    %% Emit stop telemetry
    telemetry:execute(?TELEMETRY_PROJECTION_STOP, #{}, #{
        projection => ProjectionModule
    }),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
handle_event_internal(EventType, Event, Metadata, State) ->
    #state{
        projection_module = ProjectionModule,
        projection_state = ProjectionState,
        read_model = ReadModel,
        checkpoint = Checkpoint,
        checkpoint_store = CheckpointStore
    } = State,

    %% Check for idempotency - skip if already processed
    EventVersion = maps:get(version, Metadata, 0),
    case EventVersion =< Checkpoint of
        true ->
            %% Already processed, skip
            {ok, State};
        false ->
            do_project(EventType, Event, Metadata, EventVersion,
                       ProjectionModule, ProjectionState, ReadModel,
                       CheckpointStore, State)
    end.

%% @private
do_project(EventType, Event, Metadata, EventVersion,
           ProjectionModule, ProjectionState, ReadModel,
           CheckpointStore, State) ->
    StartTime = erlang:system_time(microsecond),

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_PROJECTION_EVENT, #{
        system_time => StartTime
    }, #{
        projection => ProjectionModule,
        event_type => EventType
    }),

    %% Call the projection under a guard: a raise or an unexpected return
    %% must not crash the process and take every event queued behind this
    %% one down with it. Both map to the {error, ...} path below (no
    %% stacktrace kept, so no event data rides a stack frame downstream).
    FullEvent = Event#{event_type => EventType},
    case safe_project(ProjectionModule, FullEvent, Metadata, ProjectionState, ReadModel) of
        {ok, NewProjectionState, NewReadModel} ->
            Duration = erlang:system_time(microsecond) - StartTime,

            %% Update checkpoint
            NewRM = evoq_read_model:set_checkpoint(EventVersion, NewReadModel),

            %% Persist checkpoint if store available
            save_checkpoint(ProjectionModule, CheckpointStore, EventVersion),

            %% Emit success telemetry
            telemetry:execute(?TELEMETRY_PROJECTION_STOP, #{
                duration => Duration
            }, #{
                projection => ProjectionModule,
                event_type => EventType
            }),

            NewState = State#state{
                projection_state = NewProjectionState,
                read_model = NewRM,
                checkpoint = EventVersion
            },
            {ok, NewState};

        {skip, NewProjectionState, NewReadModel} ->
            %% Event skipped but checkpoint still advances
            NewRM = evoq_read_model:set_checkpoint(EventVersion, NewReadModel),
            save_checkpoint(ProjectionModule, CheckpointStore, EventVersion),

            NewState = State#state{
                projection_state = NewProjectionState,
                read_model = NewRM,
                checkpoint = EventVersion
            },
            {ok, NewState};

        {error, Reason} = Error ->
            Duration = erlang:system_time(microsecond) - StartTime,

            %% Emit failure telemetry
            telemetry:execute(?TELEMETRY_PROJECTION_EXCEPTION, #{
                duration => Duration
            }, #{
                projection => ProjectionModule,
                event_type => EventType,
                error => Reason
            }),

            %% Until durable redelivery lands (later slice), an error drops
            %% this event with the checkpoint unchanged and no retry. Count
            %% it and log at most once a window so the drop is not silent.
            record_drop(ProjectionModule, EventType),

            %% Check for error callback
            notify_on_error(erlang:function_exported(ProjectionModule, on_error, 4),
                            ProjectionModule, Event, Reason, ProjectionState, Error)
    end.

%% @private Invoke project/4 under a guard, normalising a raise or an
%% unexpected return into {error, Reason} so the caller's error path
%% applies. No stacktrace is retained (it can carry event data in a top
%% frame's argument list).
safe_project(ProjectionModule, FullEvent, Metadata, ProjectionState, ReadModel) ->
    try ProjectionModule:project(FullEvent, Metadata, ProjectionState, ReadModel) of
        {ok, _, _} = Ok -> Ok;
        {skip, _, _} = Skip -> Skip;
        {error, _} = Err -> Err;
        Other -> {error, {bad_return, Other}}
    catch
        Class:Reason -> {error, {Class, Reason}}
    end.

%% @private Count a dropped event and log at most once per window. State
%% lives in the process dictionary -- a projection is a single process, so
%% this is process-local and needs no record field.
record_drop(ProjectionModule, EventType) ->
    N = drop_count() + 1,
    put(dropped_events, N),
    Now = erlang:system_time(millisecond),
    Due = Now - last_drop_log_ms() >= ?DROP_LOG_WINDOW_MS,
    maybe_log_drop(Now, Due, ProjectionModule, EventType, N).

drop_count() ->
    count_or_zero(get(dropped_events)).

count_or_zero(undefined) -> 0;
count_or_zero(N) -> N.

last_drop_log_ms() ->
    count_or_zero(get(last_drop_log_ms)).

maybe_log_drop(Now, true, ProjectionModule, EventType, N) ->
    put(last_drop_log_ms, Now),
    logger:warning("[evoq] projection ~p has dropped ~b event(s) so far "
                   "(latest type ~s): checkpoint not advanced, no retry until "
                   "durable redelivery lands",
                   [ProjectionModule, N, EventType]),
    ok;
maybe_log_drop(_Now, false, _ProjectionModule, _EventType, _N) ->
    ok.

%% @private Invoke the projection's on_error/4 callback when present.
notify_on_error(true, ProjectionModule, Event, Reason, ProjectionState, Error) ->
    FailureContext = #evoq_failure_context{
        handler_module = ProjectionModule,
        event = Event,
        error = Reason,
        attempt_number = 1,
        first_failure_at = erlang:system_time(millisecond),
        last_failure_at = erlang:system_time(millisecond),
        stacktrace = []
    },
    _Action = ProjectionModule:on_error(Reason, Event, FailureContext, ProjectionState),
    Error;
notify_on_error(false, _ProjectionModule, _Event, _Reason, _ProjectionState, Error) ->
    Error.

%% @private
do_rebuild(#state{
    projection_module = ProjectionModule,
    read_model = ReadModel,
    checkpoint_store = CheckpointStore,
    event_types = EventTypes
} = State) ->
    %% Clear the read model
    case evoq_read_model:clear(ReadModel) of
        {ok, ClearedRM} ->
            %% Reset checkpoint (-1 = nothing processed yet)
            save_checkpoint(ProjectionModule, CheckpointStore, -1),

            InitialState = State#state{
                read_model = ClearedRM,
                checkpoint = -1
            },

            %% Replay all events from event store
            replay_events(InitialState, EventTypes);

        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Replay all events of the specified types from the event store.
%% Uses store_id from Opts if provided, otherwise falls back to app env.
replay_events(State, EventTypes) ->
    StoreId = case State#state.store_id of
        undefined -> application:get_env(evoq, store_id, default_store);
        Id -> Id
    end,
    BatchSize = application:get_env(evoq, replay_batch_size, 1000),

    case evoq_event_store:read_events_by_types(StoreId, EventTypes, BatchSize) of
        {ok, Events} ->
            replay_events_list(Events, State);
        {error, Reason} ->
            %% Log warning but don't fail - projection will catch up on new events
            logger:warning("Projection rebuild could not read events: ~p", [Reason]),
            {ok, State}
    end.

%% @private
%% Replay a list of events through the projection
replay_events_list([], State) ->
    {ok, State};
replay_events_list([Event | Rest], State) ->
    #state{
        projection_module = ProjectionModule,
        projection_state = ProjectionState,
        read_model = ReadModel,
        checkpoint_store = CheckpointStore
    } = State,

    EventType = maps:get(event_type, Event, <<"unknown">>),
    StreamId = maps:get(stream_id, Event, <<"unknown">>),
    Version = maps:get(version, Event, 0),

    Metadata = #{
        stream_id => StreamId,
        version => Version,
        replaying => true
    },

    %% Project the event
    FullEvent = Event#{event_type => EventType},
    case ProjectionModule:project(FullEvent, Metadata, ProjectionState, ReadModel) of
        {ok, NewProjectionState, NewReadModel} ->
            %% Update checkpoint
            NewRM = evoq_read_model:set_checkpoint(Version, NewReadModel),
            save_checkpoint(ProjectionModule, CheckpointStore, Version),

            NewState = State#state{
                projection_state = NewProjectionState,
                read_model = NewRM,
                checkpoint = Version
            },
            replay_events_list(Rest, NewState);

        {skip, NewProjectionState, NewReadModel} ->
            NewRM = evoq_read_model:set_checkpoint(Version, NewReadModel),
            save_checkpoint(ProjectionModule, CheckpointStore, Version),

            NewState = State#state{
                projection_state = NewProjectionState,
                read_model = NewRM,
                checkpoint = Version
            },
            replay_events_list(Rest, NewState);

        {error, Reason} ->
            logger:error("Projection rebuild failed on event ~p: ~p",
                        [EventType, Reason]),
            {error, {replay_failed, Reason}}
    end.

%% @private
load_checkpoint(_ProjectionModule, undefined) ->
    -1;
load_checkpoint(ProjectionModule, CheckpointStore) ->
    load_checkpoint(erlang:function_exported(CheckpointStore, load, 1),
                    ProjectionModule, CheckpointStore).

load_checkpoint(true, ProjectionModule, CheckpointStore) ->
    checkpoint_value(CheckpointStore:load(ProjectionModule));
load_checkpoint(false, _ProjectionModule, _CheckpointStore) ->
    0.

checkpoint_value({ok, Checkpoint}) -> Checkpoint;
checkpoint_value({error, _}) -> 0.

%% @private
register_self(EventType) ->
    evoq_event_type_registry:register(EventType, self()).

%% @private
save_checkpoint(_ProjectionModule, undefined, _Position) ->
    ok;
save_checkpoint(ProjectionModule, CheckpointStore, Position) ->
    case erlang:function_exported(CheckpointStore, save, 2) of
        true ->
            CheckpointStore:save(ProjectionModule, Position);
        false ->
            ok
    end.
