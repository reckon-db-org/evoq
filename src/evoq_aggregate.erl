%% @doc Aggregate behavior and GenServer implementation.
%%
%% Aggregates are the consistency boundary in event sourcing. Each aggregate:
%% - Has a unique stream ID
%% - Processes commands via execute/2 callback
%% - Applies events via apply/2 callback
%% - Supports snapshots for fast recovery
%% - Has configurable lifespan (TTL, hibernate, passivate)
%%
%% == Callbacks ==
%%
%% Required:
%% - init(AggregateId) -> {ok, State}
%% - execute(State, Command) -> {ok, [Event]} | {error, Reason}
%% - apply(State, Event) -> NewState
%%
%% Optional:
%% - snapshot(State) -> SnapshotData
%% - from_snapshot(SnapshotData) -> State
%%
%% @author rgfaber
-module(evoq_aggregate).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% Behavior callbacks
-callback init(AggregateId :: binary()) -> {ok, State :: term()}.
-callback execute(State :: term(), Command :: map()) ->
    {ok, [Event :: map()]} | {error, Reason :: term()}.
-callback apply(State :: term(), Event :: map()) -> NewState :: term().

%% Optional callbacks
-callback snapshot(State :: term()) -> SnapshotData :: term().
-callback from_snapshot(SnapshotData :: term()) -> State :: term().

-optional_callbacks([snapshot/1, from_snapshot/1]).

%% API
-export([start_link/2, start_link/3]).
-export([execute_command/2, get_state/1, get_version/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start an aggregate process (uses env store_id).
%%
%% @deprecated Use start_link/3 with explicit store_id instead.
-spec start_link(atom(), binary()) -> {ok, pid()} | {error, term()}.
start_link(AggregateModule, AggregateId) ->
    StoreId = application:get_env(evoq, store_id, default_store),
    start_link(AggregateModule, AggregateId, StoreId).

%% @doc Start an aggregate process with explicit store_id.
-spec start_link(atom(), binary(), atom()) -> {ok, pid()} | {error, term()}.
start_link(AggregateModule, AggregateId, StoreId) ->
    gen_server:start_link(?MODULE, {AggregateModule, AggregateId, StoreId}, []).

%% @doc Execute a command against an aggregate.
-spec execute_command(pid(), #evoq_command{}) ->
    {ok, non_neg_integer(), [map()]} | {error, term()}.
execute_command(Pid, Command) ->
    gen_server:call(Pid, {execute, Command}, infinity).

%% @doc Get the current state of an aggregate (for debugging).
-spec get_state(pid()) -> {ok, term()}.
get_state(Pid) ->
    gen_server:call(Pid, get_state).

%% @doc Get the current version of an aggregate.
-spec get_version(pid()) -> {ok, non_neg_integer()}.
get_version(Pid) ->
    gen_server:call(Pid, get_version).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({AggregateModule, AggregateId, StoreId}) ->
    %% Register with the registry
    evoq_aggregate_registry:register(AggregateId, self()),

    %% Get lifespan configuration
    LifespanModule = get_lifespan_module(),

    %% Try to load from snapshot, otherwise initialize fresh
    {InitialState, Version} = load_or_init(AggregateModule, AggregateId, StoreId),

    State = #evoq_aggregate_state{
        stream_id = AggregateId,
        aggregate_module = AggregateModule,
        store_id = StoreId,
        state = InitialState,
        version = Version,
        lifespan_module = LifespanModule,
        last_activity = erlang:system_time(millisecond),
        snapshot_count = 0
    },

    %% Emit telemetry
    telemetry:execute(?TELEMETRY_AGGREGATE_INIT, #{}, #{
        aggregate_id => AggregateId,
        aggregate_module => AggregateModule,
        store_id => StoreId,
        version => Version
    }),

    %% Get initial timeout from lifespan
    Timeout = get_timeout(LifespanModule, init),
    {ok, State, Timeout}.

%% @private
handle_call({execute, Command}, _From, State) ->
    #evoq_aggregate_state{
        stream_id = StreamId,
        aggregate_module = Module,
        store_id = StoreId,
        state = AggState,
        version = Version,
        lifespan_module = LifespanModule
    } = State,

    StartTime = erlang:system_time(microsecond),

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_START, #{
        system_time => StartTime
    }, #{
        aggregate_id => StreamId,
        aggregate_module => Module,
        store_id => StoreId,
        command_type => maps:get(command_type, Command#evoq_command.payload, unknown)
    }),

    %% Execute the command
    case Module:execute(AggState, Command#evoq_command.payload) of
        {ok, Events} when is_list(Events) ->
            %% Apply events to get new state
            NewAggState = lists:foldl(fun(Event, AccState) ->
                Module:apply(AccState, Event)
            end, AggState, Events),

            %% Append events to reckon-db using stored store_id
            case append_events(StoreId, StreamId, Version, Events, Command) of
                {ok, NewVersion} ->
                    %% Update state
                    NewState = State#evoq_aggregate_state{
                        state = NewAggState,
                        version = NewVersion,
                        last_activity = erlang:system_time(millisecond),
                        snapshot_count = State#evoq_aggregate_state.snapshot_count + length(Events)
                    },

                    %% Check if snapshot is needed
                    NewState2 = maybe_snapshot(NewState),

                    %% Emit stop telemetry
                    Duration = erlang:system_time(microsecond) - StartTime,
                    telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_STOP, #{
                        duration => Duration,
                        event_count => length(Events)
                    }, #{
                        aggregate_id => StreamId,
                        new_version => NewVersion
                    }),

                    Timeout = LifespanModule:after_event(hd(Events)),
                    {reply, {ok, NewVersion, Events}, NewState2, Timeout};

                {error, wrong_expected_version} ->
                    %% Rebuild from events and retry
                    {reply, {error, wrong_expected_version}, State};

                {error, Reason} = Error ->
                    Timeout = LifespanModule:after_error(Reason),
                    {reply, Error, State, Timeout}
            end;

        {error, Reason} = Error ->
            %% Emit exception telemetry
            Duration = erlang:system_time(microsecond) - StartTime,
            telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_EXCEPTION, #{
                duration => Duration
            }, #{
                aggregate_id => StreamId,
                error => Reason
            }),

            Timeout = LifespanModule:after_error(Reason),
            {reply, Error, State, Timeout}
    end;

handle_call(get_state, _From, State) ->
    {reply, {ok, State#evoq_aggregate_state.state}, State, get_remaining_timeout(State)};

handle_call(get_version, _From, State) ->
    {reply, {ok, State#evoq_aggregate_state.version}, State, get_remaining_timeout(State)};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, get_remaining_timeout(State)}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State, get_remaining_timeout(State)}.

%% @private
handle_info(timeout, State) ->
    #evoq_aggregate_state{
        stream_id = StreamId,
        lifespan_module = LifespanModule
    } = State,

    case LifespanModule:on_timeout(State#evoq_aggregate_state.state) of
        {ok, infinity} ->
            {noreply, State};
        {ok, hibernate} ->
            telemetry:execute(?TELEMETRY_AGGREGATE_HIBERNATE, #{}, #{
                aggregate_id => StreamId
            }),
            {noreply, State, hibernate};
        {ok, passivate} ->
            passivate(State);
        {ok, stop} ->
            {stop, normal, State};
        {ok, Timeout} when is_integer(Timeout) ->
            {noreply, State, Timeout};
        {snapshot, Action} ->
            NewState = save_snapshot(State),
            handle_lifespan_action(Action, NewState)
    end;

handle_info(_Info, State) ->
    {noreply, State, get_remaining_timeout(State)}.

%% @private
terminate(_Reason, #evoq_aggregate_state{stream_id = StreamId}) ->
    evoq_aggregate_registry:unregister(StreamId),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
get_lifespan_module() ->
    application:get_env(evoq, lifespan_module, evoq_aggregate_lifespan_default).

%% @private
load_or_init(Module, AggregateId, StoreId) ->
    %% Try to load snapshot first
    case try_load_snapshot(Module, StoreId, AggregateId) of
        {ok, SnapshotState, SnapshotVersion} ->
            %% Replay events after snapshot
            case replay_events(Module, StoreId, AggregateId, SnapshotVersion, SnapshotState) of
                {ok, State, Version} -> {State, Version};
                {error, _} -> init_fresh(Module, AggregateId)
            end;
        {error, not_found} ->
            %% No snapshot, replay all events or init fresh.
            %% Note: first event in a stream is version 0, so we check
            %% State =/= undefined (set by replay_events when events exist)
            %% instead of Version > 0.
            case replay_events(Module, StoreId, AggregateId, 0, undefined) of
                {ok, State, Version} when State =/= undefined -> {State, Version};
                _ -> init_fresh(Module, AggregateId)
            end
    end.

%% @private
init_fresh(Module, AggregateId) ->
    case Module:init(AggregateId) of
        {ok, State} -> {State, 0};
        _ -> {#{}, 0}
    end.

%% @private
try_load_snapshot(Module, StoreId, AggregateId) ->
    case erlang:function_exported(Module, from_snapshot, 1) of
        true ->
            case evoq_snapshot_store:load(StoreId, AggregateId) of
                {ok, #{data := Data, version := Version}} ->
                    State = Module:from_snapshot(Data),
                    {ok, State, Version};
                {error, not_found} ->
                    {error, not_found}
            end;
        false ->
            {error, not_found}
    end.

%% @private
replay_events(Module, StoreId, AggregateId, FromVersion, InitState) ->
    case evoq_event_store:read(StoreId, AggregateId, FromVersion, 1000, forward) of
        {ok, Events} when length(Events) > 0 ->
            BaseState = case InitState of
                undefined ->
                    case Module:init(AggregateId) of
                        {ok, S} -> S;
                        _ -> #{}
                    end;
                S -> S
            end,
            {FinalState, LastVersion} = lists:foldl(fun(Event, {AccState, _Ver}) ->
                NewState = Module:apply(AccState, Event),
                EventVer = maps:get(version, Event, 0),
                {NewState, EventVer}
            end, {BaseState, FromVersion}, Events),
            {ok, FinalState, LastVersion};
        {ok, []} ->
            {ok, InitState, FromVersion};
        {error, _} = Error ->
            Error
    end.

%% @private
append_events(_StoreId, _StreamId, _Version, [], _Command) ->
    {ok, 0};
append_events(StoreId, StreamId, Version, Events, Command) ->
    %% Add metadata to events
    EventsWithMeta = lists:map(fun(Event) ->
        Event#{
            causation_id => Command#evoq_command.command_id,
            correlation_id => Command#evoq_command.correlation_id,
            metadata => Command#evoq_command.metadata
        }
    end, Events),

    evoq_event_store:append(StoreId, StreamId, Version, EventsWithMeta).

%% @private
maybe_snapshot(#evoq_aggregate_state{snapshot_count = Count} = State) ->
    SnapshotEvery = application:get_env(evoq, snapshot_every, ?DEFAULT_SNAPSHOT_EVERY),
    case Count >= SnapshotEvery of
        true ->
            save_snapshot(State);
        false ->
            State
    end.

%% @private
save_snapshot(#evoq_aggregate_state{
    stream_id = StreamId,
    aggregate_module = Module,
    store_id = StoreId,
    state = AggState,
    version = Version
} = State) ->
    case erlang:function_exported(Module, snapshot, 1) of
        true ->
            SnapshotData = Module:snapshot(AggState),
            _ = evoq_snapshot_store:save(StoreId, StreamId, Version, SnapshotData, #{}),

            telemetry:execute(?TELEMETRY_AGGREGATE_SNAPSHOT_SAVE, #{}, #{
                aggregate_id => StreamId,
                store_id => StoreId,
                version => Version
            }),

            State#evoq_aggregate_state{snapshot_count = 0};
        false ->
            State
    end.

%% @private
passivate(#evoq_aggregate_state{stream_id = StreamId} = State) ->
    telemetry:execute(?TELEMETRY_AGGREGATE_PASSIVATE, #{}, #{
        aggregate_id => StreamId
    }),
    %% Save snapshot before stopping
    _NewState = save_snapshot(State),
    {stop, normal, State}.

%% @private
handle_lifespan_action(passivate, State) ->
    passivate(State);
handle_lifespan_action(stop, State) ->
    {stop, normal, State};
handle_lifespan_action(hibernate, State) ->
    {noreply, State, hibernate};
handle_lifespan_action(infinity, State) ->
    {noreply, State};
handle_lifespan_action(Timeout, State) when is_integer(Timeout) ->
    {noreply, State, Timeout}.

%% @private
get_timeout(LifespanModule, init) ->
    LifespanModule:after_command(#{}).

%% @private
get_remaining_timeout(#evoq_aggregate_state{
    lifespan_module = LifespanModule,
    last_activity = LastActivity
}) ->
    IdleTimeout = application:get_env(evoq, idle_timeout, ?DEFAULT_IDLE_TIMEOUT),
    Elapsed = erlang:system_time(millisecond) - LastActivity,
    Remaining = max(0, IdleTimeout - Elapsed),
    case Remaining of
        0 -> 0;
        _ -> LifespanModule:after_command(#{})
    end.
