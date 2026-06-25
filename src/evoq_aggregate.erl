%% @doc Aggregate behavior and GenServer implementation.
%%
%% Aggregates are the consistency boundary in event sourcing. Each aggregate:
%% - Has a unique stream ID
%% - Declares a state module via state_module/0
%% - Processes commands via execute/2 callback
%% - Applies events via apply/2 callback (typically delegates to state module)
%% - Supports snapshots for fast recovery
%% - Has configurable lifespan (TTL, hibernate, passivate)
%%
%% == Callbacks ==
%%
%% Required:
%% - state_module() -> module()
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
-callback state_module() -> module().
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
-export([execute_command/2, execute_command_with_state/2, get_state/1, get_version/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-ifdef(TEST).
-export([rebuild_from_events/3, is_wrong_version_error/1,
         is_integrity_violation/1]).
-endif.

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

%% @doc Execute a command and return the post-event aggregate state.
%%
%% Like execute_command/2 but includes the aggregate state after applying
%% all new events. Enables session-level consistency where the caller
%% receives immediate truth about the resulting state.
-spec execute_command_with_state(pid(), #evoq_command{}) ->
    {ok, non_neg_integer(), [map()], term()} | {error, term()}.
execute_command_with_state(Pid, Command) ->
    gen_server:call(Pid, {execute_with_state, Command}, infinity).

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
            %% Apply events to get new state, then append
            NewAggState = apply_events(Module, AggState, Events),
            reply_after_append(append_events(StoreId, StreamId, Version, Events, Command),
                               Events, NewAggState, State, StartTime);

        {error, Reason} = Error ->
            %% Emit exception telemetry
            emit_execute_exception(StreamId, Reason, StartTime),
            Timeout = LifespanModule:after_error(Reason),
            {reply, Error, State, Timeout}
    end;

handle_call({execute_with_state, Command}, _From, State) ->
    #evoq_aggregate_state{
        stream_id = StreamId,
        aggregate_module = Module,
        store_id = StoreId,
        state = AggState,
        version = Version,
        lifespan_module = LifespanModule
    } = State,

    StartTime = erlang:system_time(microsecond),

    telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_START, #{
        system_time => StartTime
    }, #{
        aggregate_id => StreamId,
        aggregate_module => Module,
        store_id => StoreId,
        command_type => maps:get(command_type, Command#evoq_command.payload, unknown)
    }),

    case Module:execute(AggState, Command#evoq_command.payload) of
        {ok, Events} when is_list(Events) ->
            NewAggState = apply_events(Module, AggState, Events),
            reply_after_append_with_state(
                append_events(StoreId, StreamId, Version, Events, Command),
                Events, NewAggState, State, StartTime);

        {error, Reason} = Error ->
            emit_execute_exception(StreamId, Reason, StartTime),
            Timeout = LifespanModule:after_error(Reason),
            {reply, Error, State, Timeout}
    end;

handle_call(get_state, _From, State) ->
    {reply, {ok, State#evoq_aggregate_state.state}, State, get_remaining_timeout(State)};

handle_call(get_version, _From, State) ->
    {reply, {ok, State#evoq_aggregate_state.version}, State, get_remaining_timeout(State)};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, get_remaining_timeout(State)}.

%% @private Fold new events onto the aggregate state.
apply_events(Module, State, Events) ->
    lists:foldl(fun(Event, Acc) -> Module:apply(Acc, Event) end, State, Events).

%% @private Reply after a conditional append (execute variant).
reply_after_append({ok, NewVersion}, Events, NewAggState, State, StartTime) ->
    NewState2 = commit_new_state(State, NewAggState, NewVersion, Events),
    emit_execute_stop(stream_id(State), NewVersion, Events, StartTime),
    Timeout = (State#evoq_aggregate_state.lifespan_module):after_event(hd(Events)),
    {reply, {ok, NewVersion, Events}, NewState2, Timeout};
reply_after_append(AppendError, _Events, _NewAggState, State, _StartTime) ->
    reply_after_append_error(AppendError, State,
                             State#evoq_aggregate_state.aggregate_module,
                             State#evoq_aggregate_state.store_id,
                             stream_id(State),
                             State#evoq_aggregate_state.lifespan_module).

%% @private Reply after a conditional append (execute_with_state variant).
reply_after_append_with_state({ok, NewVersion}, Events, NewAggState, State, StartTime) ->
    NewState2 = commit_new_state(State, NewAggState, NewVersion, Events),
    emit_execute_stop(stream_id(State), NewVersion, Events, StartTime),
    Timeout = (State#evoq_aggregate_state.lifespan_module):after_event(hd(Events)),
    {reply, {ok, NewVersion, Events, NewAggState}, NewState2, Timeout};
reply_after_append_with_state(AppendError, Events, NewAggState, State, StartTime) ->
    reply_after_append(AppendError, Events, NewAggState, State, StartTime).

%% @private Build + maybe-snapshot the post-append aggregate state.
commit_new_state(State, NewAggState, NewVersion, Events) ->
    NewState = State#evoq_aggregate_state{
        state = NewAggState,
        version = NewVersion,
        last_activity = erlang:system_time(millisecond),
        snapshot_count = State#evoq_aggregate_state.snapshot_count + length(Events)
    },
    maybe_snapshot(NewState).

stream_id(State) -> State#evoq_aggregate_state.stream_id.

emit_execute_stop(StreamId, NewVersion, Events, StartTime) ->
    Duration = erlang:system_time(microsecond) - StartTime,
    telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_STOP, #{
        duration => Duration,
        event_count => length(Events)
    }, #{
        aggregate_id => StreamId,
        new_version => NewVersion
    }).

emit_execute_exception(StreamId, Reason, StartTime) ->
    Duration = erlang:system_time(microsecond) - StartTime,
    telemetry:execute(?TELEMETRY_AGGREGATE_EXECUTE_EXCEPTION, #{
        duration => Duration
    }, #{
        aggregate_id => StreamId,
        error => Reason
    }).

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
    from_snapshot_or_replay(try_load_snapshot(Module, StoreId, AggregateId),
                            Module, StoreId, AggregateId).

from_snapshot_or_replay({ok, SnapshotState, SnapshotVersion}, Module, StoreId, AggregateId) ->
    %% Replay events after snapshot
    replayed_or_fresh(
        replay_events(Module, StoreId, AggregateId, SnapshotVersion, SnapshotState),
        Module, AggregateId);
from_snapshot_or_replay({error, not_found}, Module, StoreId, AggregateId) ->
    %% No snapshot, replay all events or init fresh. First event in a
    %% stream is version 0, so check State =/= undefined (set by
    %% replay_events when events exist) instead of Version > 0.
    replayed_from_zero(
        replay_events(Module, StoreId, AggregateId, 0, undefined),
        Module, AggregateId).

replayed_or_fresh({ok, State, Version}, _Module, _AggregateId) -> {State, Version};
replayed_or_fresh({error, _}, Module, AggregateId) -> init_fresh(Module, AggregateId).

replayed_from_zero({ok, State, Version}, _Module, _AggregateId) when State =/= undefined ->
    {State, Version};
replayed_from_zero(_, Module, AggregateId) ->
    init_fresh(Module, AggregateId).

%% @private
init_fresh(Module, AggregateId) ->
    case Module:init(AggregateId) of
        {ok, State} -> {State, -1};
        _ -> {#{}, -1}
    end.

%% @private
try_load_snapshot(Module, StoreId, AggregateId) ->
    load_snapshot_if_exported(erlang:function_exported(Module, from_snapshot, 1),
                              Module, StoreId, AggregateId).

load_snapshot_if_exported(true, Module, StoreId, AggregateId) ->
    snapshot_result(evoq_snapshot_store:load(StoreId, AggregateId), Module);
load_snapshot_if_exported(false, _Module, _StoreId, _AggregateId) ->
    {error, not_found}.

snapshot_result({ok, #{data := Data, version := Version}}, Module) ->
    {ok, Module:from_snapshot(Data), Version};
snapshot_result({error, not_found}, _Module) ->
    {error, not_found}.

%% @private Classify an append failure so we know whether to rebuild.
%%
%% reckon-db's append surfaces a 3-tuple `{wrong_expected_version,
%% Expected, Actual}`; earlier reckon_gater versions used a 2-tuple
%% `{wrong_expected_version, Actual}`; and some call sites still
%% produce the plain atom. Collapsing them here keeps the dispatcher's
%% 2-tuple retry contract intact regardless of which backend shape
%% bubbles up.
-spec is_wrong_version_error(term()) -> boolean().
is_wrong_version_error({error, wrong_expected_version})           -> true;
is_wrong_version_error({error, {wrong_expected_version, _}})      -> true;
is_wrong_version_error({error, {wrong_expected_version, _, _}})   -> true;
is_wrong_version_error(_)                                         -> false.

%% @doc Recognise the tamper-resistance integrity_violation error
%% class shipped by reckon-db 2.1.0 storage layer.
%%
%% Distinct from `wrong_expected_version` — must NOT enter the
%% rebuild-and-retry loop. An integrity violation indicates that
%% on-disk state has been tampered with (or that the operator's
%% HMAC key is misconfigured); retrying would either spin against
%% the same corrupted state, or — if the tamper was applied to a
%% snapshot — silently load forged state via fallback.
%%
%% Used by the aggregate's post-append error handling AND by the
%% dispatcher when classifying replay failures during rebuild.
-spec is_integrity_violation(term()) -> boolean().
is_integrity_violation({error, {integrity_violation, _}}) -> true;
is_integrity_violation(_) -> false.

%% @private Turn any append error into the correct gen_server reply.
%%
%% On a version conflict we rebuild the aggregate from the stream and
%% hand the dispatcher a normalised `{error, wrong_expected_version}`
%% so its retry loop fires exactly once per conflict. Any other error
%% is returned verbatim.
-spec reply_after_append_error(term(), #evoq_aggregate_state{}, module(),
                               atom(), binary(), module()) -> term().
reply_after_append_error(Error, State, Module, StoreId, StreamId, LifespanModule) ->
    case classify_append_error(Error) of
        integrity_violation ->
            %% Terminal — no retry, surface immediately to caller.
            %% Emit telemetry so operators can alarm on this class
            %% even when the caller swallows the error tuple.
            emit_integrity_telemetry(StoreId, StreamId, Error, append),
            {error, Reason} = Error,
            Timeout = LifespanModule:after_error(Reason),
            {reply, Error, State, Timeout};
        wrong_version ->
            rebuild_and_reply_conflict(State, Module, StoreId, StreamId);
        other ->
            {error, Reason} = Error,
            Timeout = LifespanModule:after_error(Reason),
            {reply, Error, State, Timeout}
    end.

%% @private Classify an error from the append path. Integrity
%% violation comes first because is_wrong_version_error/1 alone
%% would not distinguish it; the dispatcher must see the original
%% error tuple, not a normalised wrong_expected_version.
classify_append_error(Error) ->
    classify_append_error(is_integrity_violation(Error), Error).

classify_append_error(true, _Error) ->
    integrity_violation;
classify_append_error(false, Error) ->
    wrong_version_or_other(is_wrong_version_error(Error)).

wrong_version_or_other(true) -> wrong_version;
wrong_version_or_other(false) -> other.

emit_integrity_telemetry(StoreId, StreamId, Error, Stage) ->
    telemetry:execute(
        [evoq, aggregate, integrity, violation],
        #{system_time => erlang:system_time(millisecond)},
        #{store_id => StoreId,
          stream_id => StreamId,
          stage => Stage,
          error => Error}
    ).

-spec rebuild_and_reply_conflict(#evoq_aggregate_state{}, module(),
                                 atom(), binary()) -> term().
rebuild_and_reply_conflict(State, Module, StoreId, StreamId) ->
    rebuilt_reply(rebuild_from_events(Module, StoreId, StreamId),
                  State, StoreId, StreamId).

rebuilt_reply({ok, NewAggState, NewVersion}, State, _StoreId, _StreamId) ->
    {reply, {error, wrong_expected_version},
     State#evoq_aggregate_state{state = NewAggState, version = NewVersion}};
rebuilt_reply({error, _} = RebuildErr, State, StoreId, StreamId) ->
    %% Rebuild itself failed. Distinguish integrity from other rebuild
    %% failures: integrity_violation must surface verbatim so the
    %% dispatcher does NOT retry. Without this, the dispatcher would see
    %% wrong_expected_version, retry, rebuild would fail again with the
    %% same integrity_violation, and the loop would only stop at the cap.
    rebuild_failure_reply(is_integrity_violation(RebuildErr),
                          RebuildErr, State, StoreId, StreamId).

rebuild_failure_reply(true, RebuildErr, State, StoreId, StreamId) ->
    emit_integrity_telemetry(StoreId, StreamId, RebuildErr, rebuild),
    {reply, RebuildErr, State};
rebuild_failure_reply(false, _RebuildErr, State, _StoreId, _StreamId) ->
    {reply, {error, wrong_expected_version}, State}.

%% @private Rebuild aggregate state from the event store (full replay).
%% Used on wrong_expected_version to re-sync with the actual stream.
%%
%% An empty stream MUST report version = -1 (NO_STREAM), not 0. Otherwise
%% the dispatcher's retry loop hands the Ra backend expected_version=0 for
%% a stream at version=-1 and the next append fails forever.
rebuild_from_events(Module, StoreId, AggregateId) ->
    case replay_events(Module, StoreId, AggregateId, 0, undefined) of
        {ok, State, Version} when State =/= undefined ->
            {ok, State, Version};
        {ok, undefined, _} ->
            {State, Version} = init_fresh(Module, AggregateId),
            {ok, State, Version};
        {error, _} = Error ->
            Error
    end.

replay_events(Module, StoreId, AggregateId, FromVersion, InitState) ->
    replay_read(evoq_event_store:read(StoreId, AggregateId, FromVersion, 1000, forward),
                Module, AggregateId, FromVersion, InitState).

replay_read({ok, Events}, Module, AggregateId, FromVersion, InitState)
        when length(Events) > 0 ->
    BaseState = base_state(InitState, Module, AggregateId),
    {FinalState, LastVersion} =
        lists:foldl(fun(Event, Acc) -> apply_replayed(Module, Event, Acc) end,
                    {BaseState, FromVersion}, Events),
    {ok, FinalState, LastVersion};
replay_read({ok, []}, _Module, _AggregateId, FromVersion, InitState) ->
    {ok, InitState, FromVersion};
replay_read({error, _} = Error, _Module, _AggregateId, _FromVersion, _InitState) ->
    Error.

%% @private Initial fold state: the provided snapshot, or a fresh init.
base_state(undefined, Module, AggregateId) ->
    init_state_or_empty(Module:init(AggregateId));
base_state(S, _Module, _AggregateId) ->
    S.

init_state_or_empty({ok, S}) -> S;
init_state_or_empty(_) -> #{}.

apply_replayed(Module, Event, {AccState, _Ver}) ->
    {Module:apply(AccState, Event), maps:get(version, Event, 0)}.

%% @private
append_events(_StoreId, _StreamId, _Version, [], _Command) ->
    {ok, 0};
append_events(StoreId, StreamId, Version, Events, Command) ->
    %% Build infrastructure metadata from command
    CmdMeta = Command#evoq_command.metadata,
    %% Cross-stream tags live in command metadata under 'tags' key
    Tags = maps:get(tags, CmdMeta, undefined),
    CleanMeta = maps:without([tags], CmdMeta),
    %% Lineage propagation (EIP): the event's causation is the command that
    %% produced it; the correlation is copied forward unchanged. Keys are the
    %% canonical reserved names (see evoq.hrl / reckon_shared.proto).
    BaseMeta = CleanMeta#{
        ?EVOQ_META_CAUSATION_ID => Command#evoq_command.command_id,
        ?EVOQ_META_CORRELATION_ID => Command#evoq_command.correlation_id
    },

    %% Wrap each event into nested #{event_type, data, metadata} structure.
    %% This eliminates guesswork in the adapter — we KNOW which keys are
    %% infrastructure (we put them there) and which are business data.
    EventsNested = lists:map(fun(Event) -> wrap_event(Event, BaseMeta, Tags) end, Events),
    evoq_event_store:append(StoreId, StreamId, Version, EventsNested).

%% @private Wrap one event into a nested #{event_type, data, metadata} map,
%% attaching tags only when a non-empty list was supplied.
wrap_event(Event, BaseMeta, Tags) ->
    Wrapped = #{
        event_type => resolve_event_type(Event),
        data => maps:without([event_type], Event),
        metadata => BaseMeta
    },
    with_tags(Tags, Wrapped).

with_tags(L, Wrapped) when is_list(L), L =/= [] -> Wrapped#{tags => L};
with_tags(_Tags, Wrapped) -> Wrapped.

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

%% @private Resolve event_type to binary for storage.
%% Atom event_type values (from typed evoq_event modules) are auto-converted.
resolve_event_type(#{event_type := Type}) when is_atom(Type) ->
    atom_to_binary(Type, utf8);
resolve_event_type(#{event_type := Type}) when is_binary(Type) ->
    Type;
resolve_event_type(_) ->
    undefined.

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
