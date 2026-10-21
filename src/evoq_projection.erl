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
%%     {ok, NewState, NewReadModel}
%%   | {skip, NewState, NewReadModel}
%%   | {error, Reason}
%%   Transform event into read model updates. `skip' says the projection
%%   does not want this event; the checkpoint still advances and the event
%%   is not retried.
%%
%% Optional:
%% - on_error(Error, Event, FailureContext, State) -> error_action()
%%   Handle projection errors: retry, {retry, DelayMs}, skip, stop or
%%   {dead_letter, Reason}, exactly as for an event handler. Without it the
%%   shared default applies (backoff, then dead letter).
%%
%% - max_retries() -> pos_integer()
%% - backoff_ms(Attempt) -> pos_integer()
%%   Tune the default retry policy.
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
-include("evoq_types.hrl").
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

%% Same two knobs an event handler can turn to tune the default retry
%% policy; read by evoq_error_handler:handle_error/5.
-callback max_retries() -> pos_integer().
-callback backoff_ms(AttemptNumber :: pos_integer()) -> pos_integer().

-optional_callbacks([on_error/4, max_retries/0, backoff_ms/1]).

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
    %% Highest position projected so far; -1 when nothing has been.
    %% Positions start at 0, so "nothing yet" must sit below every one of
    %% them or the first event reads as already covered. See position/1
    %% for what a position is.
    checkpoint :: integer(),
    checkpoint_store :: atom() | undefined,
    store_id :: atom() | undefined,
    %% The Config init/1 was called with, kept so a rebuild can call it
    %% again: a rebuild replays the whole log, and replaying it on top of
    %% state that already reflects it counted every event twice. (Last in
    %% the record so the field order callers rely on does not move.)
    config :: map(),
    %% Why this projection stopped projecting, or undefined while it is
    %% healthy. A projection that could not catch up at boot, or whose
    %% on_error/4 answered stop, is HALTED: it keeps the checkpoint it
    %% reached, it answers every later event with {error, {halted, Reason}}
    %% instead of projecting it, and a successful rebuild/1 clears it. The
    %% flag is what makes "halted and behind" a state rather than a log
    %% line - without it the projection kept serving and moved the
    %% checkpoint past the event it had refused, which is exactly the
    %% permanent hole the resume exists to remove.
    halted :: undefined | term()
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
-spec start_link(atom(), map(), map()) -> {ok, pid()} | {error, term()}.
start_link(ProjectionModule, Config, Opts) ->
    gen_server:start_link(?MODULE, {ProjectionModule, Config, Opts}, []).

%% @doc Get event types this projection handles.
-spec get_event_types(pid()) -> [binary()].
get_event_types(Pid) ->
    gen_server:call(Pid, get_event_types).

%% @doc Get the current checkpoint position: the highest position projected
%% so far (the store's global position for events from the store
%% subscription or a rebuild), or -1 when nothing has been projected yet.
-spec get_checkpoint(pid()) -> integer().
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

            State = #state{
                projection_module = ProjectionModule,
                config = Config,
                projection_state = ProjectionState,
                read_model = ReadModel,
                event_types = EventTypes,
                checkpoint = Checkpoint,
                checkpoint_store = CheckpointStore,
                store_id = OverrideStoreId
            },
            start_projection(State);

        {error, Reason} ->
            {stop, Reason}
    end.

%% @private Catch up on what was missed, then start serving.
%%
%% The order matters. Registration is what makes the event router deliver to
%% this process, and it delivers with gen_server:call(..., infinity): a
%% projection that replayed while registered would hold up every other
%% handler and process manager on the node for the length of the catch-up.
%% So: replay while unregistered, register, then replay again from the
%% position the first pass reached - events that arrived in between are not
%% in the live feed for a process that was not registered yet. The checkpoint
%% dedupe makes the overlap free.
%%
%% A projection never refuses to boot. One that cannot catch up comes up
%% halted and behind: the state carries the checkpoint it actually reached,
%% `halted' says why, the halt is logged and counted in telemetry once, and
%% a rebuild after the cause is fixed recovers it. Refusing would turn one
%% poison event into a restart loop, and a statically supervised projection
%% into a failed application boot.
%%
%% A halt in the first pass skips the second: the same poison event would
%% halt it too and the operator would get two error logs and two
%% [evoq, projection, halted] events for one failure.
start_projection(#state{event_types = EventTypes, projection_module = ProjectionModule} = State) ->
    %% Before the catch-up, not after: a dashboard that reads [evoq,
    %% projection, event] for a long resume should not see it arrive before
    %% the projection has said it started.
    telemetry:execute(?TELEMETRY_PROJECTION_START, #{}, #{
        projection => ProjectionModule
    }),

    {Resumed, FirstStatus} = resume_after_checkpoint(State),

    ok = evoq_event_type_registry:register_all(EventTypes, self()),

    Final = note_halt(second_pass(Resumed, FirstStatus)),
    {ok, Final}.

%% @private The second replay pass, or the first pass's verdict if it halted.
second_pass(State, ok) ->
    resume_after_checkpoint(State);
second_pass(State, {halted, _} = Halted) ->
    {State, Halted}.

%% @private Record the verdict of the boot resume, saying so once.
note_halt({State, ok}) ->
    State#state{halted = undefined};
note_halt({State, {halted, Reason}}) ->
    report_halt(State#state.projection_module, Reason),
    State#state{halted = Reason}.

%% @private Say that the projection halted, once, with the reason it halted.
report_halt(ProjectionModule, Reason) ->
    logger:error(#{what => evoq_projection_halted_behind,
                   projection => ProjectionModule,
                   error => Reason}),
    telemetry:execute(?TELEMETRY_PROJECTION_HALTED, #{}, #{
        projection => ProjectionModule,
        error => Reason
    }),
    ok.

%% @private
handle_call(get_event_types, _From, #state{event_types = Types} = State) ->
    {reply, Types, State};

handle_call(get_checkpoint, _From, #state{checkpoint = Checkpoint} = State) ->
    {reply, Checkpoint, State};

handle_call(get_read_model, _From, #state{read_model = RM} = State) ->
    {reply, RM, State};

handle_call({rebuild, _Opts}, _From, State) ->
    case do_rebuild(State) of
        {NewState, ok} ->
            %% The replay reached the end: whatever halted it before is
            %% gone, so the projection projects again.
            {reply, ok, NewState#state{halted = undefined}};
        {NewState, {halted, Reason}} ->
            %% The read model is cleared and the replay stopped part-way.
            %% Keep what the replay reached: the old state no longer
            %% matches the empty read model, and replying ok would serve a
            %% partial read model as a complete one. The projection stays
            %% halted, now on what the rebuild hit.
            {reply, {error, Reason}, NewState#state{halted = Reason}};
        {init_failed, Reason} ->
            %% init/1 could not give us a state to match the cleared read
            %% model, and there is no honest state to carry, so this stops
            %% the way a boot whose init/1 fails does; the supervisor
            %% restarts it and init/1 runs again.
            {stop, Reason, {error, Reason}, State};
        {error, Reason} ->
            %% Nothing was cleared, so nothing has changed.
            {reply, {error, Reason}, State}
    end;

%% @private A halted projection answers every later event the same way.
%%
%% It is registered (that is how the router reaches it), so the events keep
%% arriving; projecting them would serve a read model with a hole and move
%% the checkpoint past the event the projection refused, which is the
%% permanent loss this whole path exists to prevent. The router logs the
%% error reply, which is the standing signal to rebuild.
handle_call({notify, _EventType, _Event, _Metadata}, _From,
            #state{halted = Reason} = State) when Reason =/= undefined ->
    {reply, {error, {halted, Reason}}, State};

handle_call({notify, EventType, Event, Metadata}, _From, State) ->
    case handle_event_internal(EventType, Event, Metadata, State) of
        {ok, NewState} ->
            {reply, ok, NewState};
        {stop, Reason} ->
            %% The projection's on_error/4 chose stop: reply first, then end,
            %% so a caller blocked in notify/4 is not left guessing.
            {stop, Reason, {error, Reason}, State}
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
        checkpoint = Checkpoint
    } = State,

    %% Check for idempotency - skip if already processed
    EventVersion = position(Metadata),
    case EventVersion =< Checkpoint of
        true ->
            %% Already processed, skip
            {ok, State};
        false ->
            FailureContext = #evoq_failure_context{
                handler_module = ProjectionModule,
                event = Event,
                error = undefined,
                attempt_number = 1,
                first_failure_at = erlang:system_time(millisecond),
                last_failure_at = erlang:system_time(millisecond),
                stacktrace = []
            },
            project_with_retry(EventType, Event, Metadata, EventVersion,
                               FailureContext, State)
    end.

%% @private
%%
%% A projection that returns {error, Reason} is handled exactly as an event
%% handler is: the module's on_error/4 decides retry, {retry, DelayMs},
%% skip, stop or {dead_letter, Reason}, and without one the shared default
%% applies (backoff, then dead letter after max_retries). Before this, the
%% action was computed and thrown away, the error was returned to a router
%% that discarded the reply, and the next event successfully projected
%% jumped the checkpoint past the one that had failed: the event was lost
%% for good and nothing said so.
project_with_retry(EventType, Event, Metadata, EventVersion, FailureContext, State) ->
    #state{
        projection_module = ProjectionModule,
        projection_state = ProjectionState,
        read_model = ReadModel
    } = State,

    StartTime = evoq_telemetry:monotonic_start(),

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_PROJECTION_EVENT, #{
        system_time => erlang:system_time()
    }, #{
        projection => ProjectionModule,
        event_type => EventType,
        attempt => FailureContext#evoq_failure_context.attempt_number
    }),

    %% Call the projection
    FullEvent = Event#{event_type => EventType},
    case call_project(ProjectionModule, FullEvent, Metadata, ProjectionState, ReadModel) of
        {ok, NewProjectionState, NewReadModel} ->
            project_succeeded(EventType, EventVersion, NewProjectionState, NewReadModel,
                              StartTime, State);

        {skip, NewProjectionState, NewReadModel} ->
            %% Event skipped but checkpoint still advances
            advance_checkpoint(EventVersion,
                               State#state{projection_state = NewProjectionState,
                                           read_model = NewReadModel});

        {error, Reason} ->
            projection_failed(EventType, Event, Metadata, EventVersion, Reason,
                              StartTime, FailureContext, State)
    end.

%% @private Call project/4 so that a raise is an error like any other.
%%
%% Without this, a projection that raises - a badmatch, a badkey, a failing
%% `{ok, RM2} = evoq_read_model:put(...)` - escaped through the replay's
%% `try ... of' body (which does not cover it) and killed the process inside
%% init/1: a restart loop at boot, and `rebuild/1` exiting its caller. A
%% raise is the common way a projection fails, so "a raise and {error,_}
%% report the same way" only became true once project/4 ran inside a try.
%% The stacktrace is logged here; what on_error/4 and telemetry see is the
%% class and the reason.
call_project(ProjectionModule, Event, Metadata, ProjectionState, ReadModel) ->
    try
        ProjectionModule:project(Event, Metadata, ProjectionState, ReadModel)
    catch
        Class:Reason:Stack ->
            logger:error(#{what => evoq_projection_raised,
                           projection => ProjectionModule,
                           class => Class,
                           reason => Reason,
                           stacktrace => Stack}),
            {error, {Class, Reason}}
    end.

%% @private
project_succeeded(EventType, EventVersion, NewProjectionState, NewReadModel,
                  StartTime, #state{projection_module = ProjectionModule} = State) ->
    Duration = evoq_telemetry:duration_since(StartTime),

    %% Emit success telemetry
    telemetry:execute(?TELEMETRY_PROJECTION_STOP, #{
        duration => Duration
    }, #{
        projection => ProjectionModule,
        event_type => EventType
    }),

    advance_checkpoint(EventVersion,
                       State#state{projection_state = NewProjectionState,
                                   read_model = NewReadModel}).

%% @private
projection_failed(EventType, Event, Metadata, EventVersion, Reason,
                  StartTime, FailureContext, #state{projection_module = ProjectionModule} = State) ->
    Duration = evoq_telemetry:duration_since(StartTime),

    %% Emit failure telemetry
    telemetry:execute(?TELEMETRY_PROJECTION_EXCEPTION, #{
        duration => Duration
    }, #{
        projection => ProjectionModule,
        event_type => EventType,
        error => Reason
    }),

    UpdatedContext = FailureContext#evoq_failure_context{
        error = Reason,
        last_failure_at = erlang:system_time(millisecond)
    },

    %% Ask the projection (or the shared default) what to do next
    Action = evoq_error_handler:handle_error(
        ProjectionModule, Reason, Event, UpdatedContext,
        State#state.projection_state
    ),

    execute_error_action(Action, EventType, Event, Metadata, EventVersion,
                         UpdatedContext, State).

%% @private
execute_error_action(retry, EventType, Event, Metadata, EventVersion,
                     FailureContext, State) ->
    project_with_retry(EventType, Event, Metadata, EventVersion,
                       increment_attempt(FailureContext), State);

execute_error_action({retry, DelayMs}, EventType, Event, Metadata, EventVersion,
                     FailureContext, State) ->
    timer:sleep(DelayMs),
    project_with_retry(EventType, Event, Metadata, EventVersion,
                       increment_attempt(FailureContext), State);

execute_error_action(skip, _EventType, Event, Metadata, _EventVersion,
                     FailureContext, State) ->
    %% Skipped, but the checkpoint still advances: the projection said it does
    %% not want this event, which is not the same as failing to see it. Said
    %% out loud, because a skip is a hole in the read model.
    log_dropped(skip, Event, Metadata, FailureContext, State),
    advance_checkpoint(position(Metadata), State);

execute_error_action(stop, _EventType, _Event, _Metadata, _EventVersion,
                     FailureContext, _State) ->
    {stop, {projection_stopped, FailureContext#evoq_failure_context.error}};

execute_error_action({dead_letter, Reason}, _EventType, Event, Metadata,
                     EventVersion, FailureContext,
                     #state{projection_module = ProjectionModule} = State) ->
    _ = evoq_dead_letter:store(Event, ProjectionModule, FailureContext, Reason),
    log_dropped({dead_letter, Reason}, Event, Metadata, FailureContext, State),
    advance_checkpoint(EventVersion, State).

%% @private A retry re-runs project/4 on the same state; nothing has moved.
increment_attempt(#evoq_failure_context{attempt_number = N} = Ctx) ->
    Ctx#evoq_failure_context{attempt_number = N + 1}.

%% @private
log_dropped(Why, Event, Metadata, #evoq_failure_context{attempt_number = Attempt,
                                                        error = Error},
            #state{projection_module = ProjectionModule}) ->
    logger:warning(#{what => evoq_projection_dropped_event,
                     projection => ProjectionModule,
                     action => Why,
                     event_type => maps:get(event_type, Event, undefined),
                     event_id => maps:get(event_id, Metadata, undefined),
                     position => position(Metadata),
                     attempts => Attempt,
                     error => Error}).

%% @private Move the checkpoint (stored and in memory) to EventVersion.
advance_checkpoint(EventVersion,
                   #state{projection_module = ProjectionModule,
                          read_model = ReadModel,
                          checkpoint_store = CheckpointStore} = State) ->
    NewRM = evoq_read_model:set_checkpoint(EventVersion, ReadModel),
    save_checkpoint(ProjectionModule, CheckpointStore, EventVersion),
    {ok, State#state{read_model = NewRM, checkpoint = EventVersion}}.

%% @private The number a projection checkpoints on, and so the number that
%% decides "already projected" after a restart (evoq #1).
%%
%% Events from the store subscription and from a rebuild carry
%% `global_position': the event's index in the store's global log, which
%% names the same event in every boot. `version' there is the subscription's
%% per-boot counter, which restarts at 0 and only counts events that have a
%% handler, so a checkpoint saved from it pointed at a different event as
%% soon as the set of handlers changed between boots: events appended while
%% the node was down were skipped, or already-projected ones repeated.
%%
%% `version' remains the fallback for events delivered directly with
%% notify/4. A projection must take its events from one of the two sources:
%% the two numbers are not comparable, and a checkpoint of one skips the
%% other wrongly.
-spec position(map()) -> integer().
position(#{global_position := Position}) -> Position;
position(Metadata) -> maps:get(version, Metadata, 0).

%% @private A rebuild starts from nothing: the read model is cleared, the
%% checkpoint is reset, and init/1 runs again so the projection state is as
%% fresh as the read model. Keeping the old state replayed the whole log on
%% top of state that already reflected it.
%%
%% init/1 returns a read model of its own; it is discarded, because the
%% cleared one is the table the projection has been writing to and clearing
%% is what a rebuild means. A projection that builds a new table in init/1
%% gets a second, empty one on every rebuild.
do_rebuild(#state{
    projection_module = ProjectionModule,
    config = Config,
    read_model = ReadModel,
    checkpoint_store = CheckpointStore,
    event_types = EventTypes
} = State) ->
    %% Clear the read model
    case evoq_read_model:clear(ReadModel) of
        {ok, ClearedRM} ->
            %% Reset checkpoint (-1 = nothing processed yet)
            save_checkpoint(ProjectionModule, CheckpointStore, -1),

            rebuild_with_fresh_state(ProjectionModule, Config, ClearedRM,
                                     EventTypes, State);

        {error, Reason} ->
            {error, Reason}
    end.

%% @private
rebuild_with_fresh_state(ProjectionModule, Config, ClearedRM, EventTypes, State) ->
    case ProjectionModule:init(Config) of
        {ok, ProjectionState, _ReadModelFromInit} ->
            InitialState = State#state{
                projection_state = ProjectionState,
                read_model = ClearedRM,
                checkpoint = -1
            },

            %% Replay all events from event store
            replay_events(InitialState, EventTypes, 0);

        {error, Reason} ->
            %% The read model is already cleared and the checkpoint at -1,
            %% and init/1 could not give us a state to match them with.
            %% There is no honest state to carry over an empty read model -
            %% the old one describes data that is gone - so this stops, the
            %% same way a boot whose init/1 fails stops. The supervisor
            %% restarts it and init/1 runs again.
            {init_failed, {rebuild_init_failed, ProjectionModule, Reason}}
    end.

%% @private
%% Replay every event of the projection's types from the event store, page by
%% page through the store's global log, so a rebuild is not capped at one
%% batch and each event is checkpointed on the same global position the
%% store subscription gives it (see position/1). A rebuild and the live feed
%% then agree on which events the checkpoint covers.
%% Uses store_id from Opts if provided, otherwise falls back to app env.
replay_events(State, EventTypes, StartPosition) ->
    StoreId = case State#state.store_id of
        undefined -> application:get_env(evoq, store_id, default_store);
        Id -> Id
    end,
    BatchSize = application:get_env(evoq, replay_batch_size, 1000),
    replay_page(StoreId, EventTypes, StartPosition, BatchSize, State).

%% @private Catch up from the checkpoint, if there is one.
%%
%% A projection that stopped - on_error/4 answered stop, or the node
%% restarted - comes back at its checkpoint, but the node's shared `$all'
%% subscription has already moved past the events it missed and will not
%% deliver them to it again. Replaying from the checkpoint is what makes a
%% restart resume instead of leaving a permanent hole behind it.
%%
%% Only when there is a checkpoint: a projection's first boot must not replay
%% the whole log on top of the backfill the store subscription already
%% performs for it. A store that answers something which is not a position
%% is not something to resume from either.
%%
%% Returns `{State, ok}' when it caught up, `{State, {halted, Reason}}' when
%% it did not, and `{State, {halted, Reason}}' when it never started. A halt
%% is not a failure to start: the state carried out is the one the replay
%% reached, so everything before the poison event is projected exactly once
%% and the checkpoint says where the replay stopped.
resume_after_checkpoint(#state{checkpoint = Checkpoint} = State)
        when is_integer(Checkpoint), Checkpoint >= 0 ->
    replay_events(State, State#state.event_types, Checkpoint + 1);
resume_after_checkpoint(State) ->
    {State, ok}.

%% @private Read one page at Offset, project the matching events in it, and
%% go on to the next page unless this one was short.
%%
%% A store that cannot be read halts the replay rather than reporting an
%% empty success: a rebuild that replied ok over a partial read model is the
%% same lie as a swallowed projection error.
replay_page(StoreId, EventTypes, Offset, BatchSize, State) ->
    try evoq_event_store:read_all_global(StoreId, Offset, BatchSize) of
        {ok, Events} ->
            Matching = [{Position, Routable}
                        || {Position, {Event, _} = Routable} <- positioned(Events, Offset),
                           lists:member(maps:get(event_type, Event, undefined),
                                        EventTypes)],
            next_page(replay_events_list(Matching, State), length(Events) < BatchSize,
                      StoreId, EventTypes, Offset + length(Events), BatchSize);
        {error, Reason} ->
            {State, {halted, {read_all_global, Reason}}}
    catch
        Class:Reason:Stack ->
            %% The stack goes to the log, not into the value the caller and
            %% the telemetry metadata get.
            logger:error(#{what => evoq_projection_replay_raised,
                           class => Class,
                           reason => Reason,
                           stacktrace => Stack}),
            {State, {halted, {Class, Reason}}}
    end.

next_page({ok, State}, true, _StoreId, _EventTypes, _Offset, _BatchSize) ->
    {State, ok};
next_page({ok, State}, false, StoreId, EventTypes, Offset, BatchSize) ->
    replay_page(StoreId, EventTypes, Offset, BatchSize, State);
next_page({halted, State, Reason}, _Last, _StoreId, _EventTypes, _Offset, _BatchSize) ->
    %% Stopped where the failure was, carrying the state reached so far: the
    %% caller starts from it (resume) or reports it (rebuild), and nothing
    %% already projected is projected again.
    {State, {halted, Reason}}.

%% @private Pair each event of a page read at Offset with its global position,
%% as the {Event, Metadata} the store subscription routes, so a projection
%% sees the same event shape in a rebuild as from the live feed.
positioned(Events, Offset) ->
    lists:zip(lists:seq(Offset, Offset + length(Events) - 1),
              [routable(E) || E <- Events]).

%% @private The store subscription's shape for an adapter's event record.
routable(#evoq_event{} = E) ->
    evoq_store_subscription:evoq_event_to_routable(E).

%% @private Replay positioned events through the projection.
%%
%% The same path the live feed takes - checkpoint dedupe, project/4, the
%% on_error/4 actions - so a rebuild and a restart cannot disagree about
%% what a failure means, and an event already covered is skipped rather than
%% projected twice.
replay_events_list([], State) ->
    {ok, State};
replay_events_list([{Position, {Event, EventMetadata}} | Rest], State) ->
    EventType = maps:get(event_type, Event, <<"unknown">>),
    Metadata = EventMetadata#{global_position => Position, replaying => true},
    case handle_event_internal(EventType, Event, Metadata, State) of
        {ok, NewState} -> replay_events_list(Rest, NewState);
        {stop, Reason} -> {halted, State, Reason}
    end.

%% @private
load_checkpoint(_ProjectionModule, undefined) ->
    -1;
load_checkpoint(ProjectionModule, CheckpointStore) ->
    %% Loaded first: function_exported/3 answers false for a module that is
    %% not loaded yet, and a store named in Opts has usually never been
    %% called before this - which read as "no store", so a projection that
    %% had one started with nothing to resume from.
    _ = code:ensure_loaded(CheckpointStore),
    load_checkpoint(erlang:function_exported(CheckpointStore, load, 1),
                    ProjectionModule, CheckpointStore).

load_checkpoint(true, ProjectionModule, CheckpointStore) ->
    checkpoint_value(CheckpointStore:load(ProjectionModule));
load_checkpoint(false, _ProjectionModule, _CheckpointStore) ->
    -1.

%% A store with nothing saved yet (every projection's first boot) answers
%% `{error, not_found}': nothing projected, so -1, the same as having no
%% store at all. This read 0, which made version 0 look already covered and
%% dropped the first event without a word.
%%
%% Anything else that is not a position is also answered as "nothing
%% projected", with a warning, because the alternative is silent death:
%% `0 =< undefined' is true in Erlang (numbers sort below atoms), so a
%% checkpoint of `undefined' marked EVERY event as already projected and the
%% projection served nothing, forever, without a line.
checkpoint_value({ok, Checkpoint}) when is_integer(Checkpoint) ->
    Checkpoint;
checkpoint_value({ok, Other}) ->
    logger:warning(#{what => evoq_projection_bad_checkpoint,
                     checkpoint => Other}),
    -1;
checkpoint_value({error, _}) -> -1.

%% @private A checkpoint save is the projection's progress, and the one
%% number that says whether it is still moving. Emitted on every save, with
%% or without a store, so a projection that has stalled is visible instead
%% of merely quiet: the event was declared in evoq_telemetry.hrl and never
%% emitted.
save_checkpoint(ProjectionModule, CheckpointStore, Position) ->
    telemetry:execute(?TELEMETRY_PROJECTION_CHECKPOINT, #{}, #{
        projection => ProjectionModule,
        position => Position
    }),
    save_checkpoint_to_store(CheckpointStore, ProjectionModule, Position).

%% @private
save_checkpoint_to_store(undefined, _ProjectionModule, _Position) ->
    ok;
save_checkpoint_to_store(CheckpointStore, ProjectionModule, Position) ->
    _ = code:ensure_loaded(CheckpointStore),
    case erlang:function_exported(CheckpointStore, save, 2) of
        true ->
            CheckpointStore:save(ProjectionModule, Position);
        false ->
            ok
    end.
