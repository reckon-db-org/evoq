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
    checkpoint_store :: atom() | undefined
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

            %% Load checkpoint if store available
            Checkpoint = load_checkpoint(ProjectionModule, CheckpointStore),

            %% Register with event type registry
            lists:foreach(fun(EventType) ->
                evoq_event_type_registry:register(EventType, self())
            end, EventTypes),

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
                checkpoint_store = CheckpointStore
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

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

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

    %% Call the projection
    FullEvent = Event#{event_type => EventType},
    case ProjectionModule:project(FullEvent, Metadata, ProjectionState, ReadModel) of
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

            %% Check for error callback
            case erlang:function_exported(ProjectionModule, on_error, 4) of
                true ->
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
                false ->
                    Error
            end
    end.

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
            %% Reset checkpoint
            save_checkpoint(ProjectionModule, CheckpointStore, 0),

            InitialState = State#state{
                read_model = ClearedRM,
                checkpoint = 0
            },

            %% Replay all events from event store
            replay_events(InitialState, EventTypes);

        {error, Reason} ->
            {error, Reason}
    end.

%% @private
%% Replay all events of the specified types from the event store
replay_events(State, EventTypes) ->
    StoreId = application:get_env(evoq, store_id, default_store),
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
    0;
load_checkpoint(ProjectionModule, CheckpointStore) ->
    case erlang:function_exported(CheckpointStore, load, 1) of
        true ->
            case CheckpointStore:load(ProjectionModule) of
                {ok, Checkpoint} -> Checkpoint;
                {error, _} -> 0
            end;
        false ->
            0
    end.

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
