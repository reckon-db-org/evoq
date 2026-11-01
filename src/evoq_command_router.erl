%% @doc Command dispatcher with middleware pipeline.
%%
%% Dispatches commands through the middleware chain to aggregates.
%% Supports idempotency, retries, and consistency guarantees.
%%
%% == Dispatch Flow ==
%%
%% 1. Create execution context
%% 2. Run before_dispatch middleware (a halt answers here and touches no cache)
%% 3. Check the idempotency cache -- AFTER the gate, so a replay is still
%%    subject to it (evoq#46); a hit answers from the cache and executes nothing
%% 4. Get or start aggregate
%% 5. Execute command on aggregate
%% 6. Run after_dispatch or after_failure middleware
%% 7. Handle consistency (wait for handlers if strong)
%% 8. Cache result for idempotency
%%
%% @author rgfaber
-module(evoq_command_router).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([dispatch/2, dispatch_with_state/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Dispatch a command through the middleware pipeline.
%%
%% If command_id is undefined, auto-generates one.
%% If idempotency_key is set, uses it for deduplication cache.
%% Otherwise, command_id is used (each dispatch is unique).
%%
%% ⚠ THE `before_dispatch' CHAIN RUNS BEFORE THE IDEMPOTENCY CACHE IS CONSULTED
%% (evoq#46). It used to be the other way round, so a command replayed with a
%% known `idempotency_key' was answered from the cache without a single
%% middleware being asked: an authorization revoked since the first dispatch, a
%% maintenance window, a kill switch -- none of them saw the replay, and the
%% caller kept being handed the stored success. A replay still does not re-run
%% the command; what changed is that the chain decides about the CALLER first.
-spec dispatch(#evoq_command{}, map()) -> {ok, integer(), [map()]} | {error, term()}.
dispatch(Command0, Opts) ->
    %% Auto-generate command_id if not provided
    Command = evoq_command:ensure_id(Command0),
    dispatch_internal(Command, Opts, cache_key(Command), idempotency_ttl()).

%% @doc Dispatch a command and return the post-event aggregate state.
%%
%% Like dispatch/2 but includes the aggregate state after applying all
%% new events. Enables session-level consistency where the caller
%% receives immediate truth about the resulting state.
-spec dispatch_with_state(#evoq_command{}, map()) ->
    {ok, integer(), [map()], term()} | {error, term()}.
dispatch_with_state(Command0, Opts) ->
    Command = evoq_command:ensure_id(Command0),
    dispatch_internal_with_state(Command, Opts, cache_key(Command), idempotency_ttl()).

%% @private Use idempotency_key for the cache if provided, otherwise command_id.
cache_key(#evoq_command{idempotency_key = undefined} = Command) ->
    Command#evoq_command.command_id;
cache_key(#evoq_command{idempotency_key = Key}) ->
    Key.

%% @private
idempotency_ttl() ->
    application:get_env(evoq, idempotency_ttl, ?DEFAULT_IDEMPOTENCY_TTL).

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
dispatch_internal(Command, Opts, CacheKey, TTL) ->
    StartTime = evoq_telemetry:monotonic_start(),

    %% Create execution context
    Context = evoq_execution_context:new(Command, Opts),

    %% Create pipeline
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },

    %% Get middleware chain
    DefaultMiddleware = application:get_env(evoq, middleware, []),
    ExtraMiddleware = maps:get(middleware, Opts, []),
    Middleware = DefaultMiddleware ++ ExtraMiddleware,

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_DISPATCH_START, #{
        system_time => erlang:system_time()
    }, #{
        command_id => Command#evoq_command.command_id,
        command_type => Command#evoq_command.command_type,
        aggregate_id => Command#evoq_command.aggregate_id
    }),

    %% Run before_dispatch middleware
    Pipeline2 = run_before_dispatch(Pipeline, Middleware),

    %% Check if pipeline was halted
    case evoq_middleware:halted(Pipeline2) of
        true ->
            halted_response(Pipeline2, StartTime, Command);
        false ->
            %% Execute the command, unless this exact dispatch was already answered
            execute_unless_cached(Pipeline2, Middleware, StartTime, Command, CacheKey, TTL)
    end.

%% @private
dispatch_internal_with_state(Command, Opts, CacheKey, TTL) ->
    StartTime = evoq_telemetry:monotonic_start(),
    Context = evoq_execution_context:new(Command, Opts),
    Pipeline = #evoq_pipeline{
        command = Command,
        context = Context,
        assigns = #{},
        halted = false,
        response = undefined
    },
    DefaultMiddleware = application:get_env(evoq, middleware, []),
    ExtraMiddleware = maps:get(middleware, Opts, []),
    Middleware = DefaultMiddleware ++ ExtraMiddleware,

    telemetry:execute(?TELEMETRY_DISPATCH_START, #{
        system_time => erlang:system_time()
    }, #{
        command_id => Command#evoq_command.command_id,
        command_type => Command#evoq_command.command_type,
        aggregate_id => Command#evoq_command.aggregate_id
    }),

    Pipeline2 = run_before_dispatch(Pipeline, Middleware),

    case evoq_middleware:halted(Pipeline2) of
        true ->
            halted_response(Pipeline2, StartTime, Command);
        false ->
            execute_unless_cached(Pipeline2, Middleware, StartTime, Command, CacheKey, TTL,
                                  fun execute_and_finalize_with_state/3)
    end.

%% @private
%% The gate has already allowed this command; now the cache gets its say
%% (evoq#46).
%%
%% A command replayed with a known `idempotency_key' does NOT run again -- that
%% is what the cache is for -- but the cache is consulted only after
%% `before_dispatch' has run, so a replay is still subject to whatever the chain
%% decides about the caller: a revoked authorization, a maintenance window, a
%% kill switch. Before this the cache answered first and no middleware was ever
%% asked.
execute_unless_cached(Pipeline, Middleware, StartTime, Command, CacheKey, TTL) ->
    execute_unless_cached(Pipeline, Middleware, StartTime, Command, CacheKey, TTL,
                          fun execute_and_finalize/3).

%% @private
execute_unless_cached(Pipeline, Middleware, StartTime, Command, CacheKey, TTL, Execute) ->
    Run = fun() -> Execute(Pipeline, Middleware, StartTime) end,
    case evoq_idempotency:lookup(CacheKey) of
        {ok, Cached} ->
            %% Answered from the cache: the dispatch still started, so it also
            %% stops, with the response the caller is given.
            emit_stop_telemetry(StartTime, Command, Cached),
            Cached;
        not_found ->
            evoq_idempotency:check_and_store(CacheKey, Run, TTL)
    end.

%% @private
%% The answer to a halted pipeline (evoq#41).
%%
%% `halt/1' and `respond/2' are separate calls, and a middleware that only wants
%% to stop the command -- a maintenance window, a kill switch, a feature flag --
%% has no reason to call `respond/2'. The pipeline is built with
%% `response = undefined', so without this the router handed `undefined' back to
%% the caller, and a caller that denies only on `{error, _}' read a refusal as
%% "not an error" and accepted a command that never ran.
%%
%% A halt that said nothing is therefore a refusal with a name, never
%% `undefined'. A halt that DID respond is returned exactly as the middleware
%% gave it: that is the middleware's decision to make, not the router's.
halted_response(Pipeline, StartTime, Command) ->
    Response = case evoq_middleware:get_response(Pipeline) of
        undefined -> {error, halted_without_response};
        Given -> Given
    end,
    emit_stop_telemetry(StartTime, Command, Response),
    Response.

%% @private
execute_and_finalize_with_state(Pipeline, Middleware, StartTime) ->
    Command = Pipeline#evoq_pipeline.command,
    Context = Pipeline#evoq_pipeline.context,
    AggregateType = Command#evoq_command.aggregate_type,
    AggregateId = Command#evoq_command.aggregate_id,
    StoreId = Context#evoq_execution_context.store_id,

    case evoq_aggregate_registry:get_or_start(AggregateType, AggregateId, StoreId) of
        {ok, Pid} ->
            execute_on_aggregate_with_state(Pipeline, Pid, Middleware, StartTime, Context);
        {error, Reason} ->
            handle_failure(Pipeline, {error, Reason}, Middleware, StartTime)
    end.

%% @private
execute_on_aggregate_with_state(Pipeline, Pid, Middleware, StartTime, Context) ->
    Command = Pipeline#evoq_pipeline.command,
    Waiter = open_waiter(Context),

    try evoq_aggregate:execute_command_with_state(Pid, Command) of
        {ok, Version, Events, AggState} ->
            BaseResult = {ok, Version, Events},
            Pipeline2 = evoq_middleware:assign(events, Events, Pipeline),
            Pipeline3 = evoq_middleware:assign(version, Version, Pipeline2),
            Pipeline4 = evoq_middleware:respond(BaseResult, Pipeline3),
            Pipeline5 = evoq_middleware:chain(Pipeline4, after_dispatch, Middleware),

            ConsistencyResult = handle_consistency(keep_response_if_erased(Pipeline5, BaseResult),
                                                   Context, Waiter, Version),
            FinalResult = with_agg_state(ConsistencyResult, AggState),
            emit_stop_telemetry(StartTime, Command, ConsistencyResult),
            FinalResult;

        {error, wrong_expected_version} = Error ->
            maybe_retry(Pipeline, Error, Middleware, StartTime, Context);

        {error, _Reason} = Error ->
            handle_failure(Pipeline, Error, Middleware, StartTime)
    after
        close_waiter(Waiter)
    end.

%% @private Carry the post-command aggregate state into a successful result.
with_agg_state({ok, V, E}, AggState) -> {ok, V, E, AggState};
with_agg_state(Other, _AggState) -> Other.

%% @private
run_before_dispatch(Pipeline, Middleware) ->
    evoq_middleware:chain(Pipeline, before_dispatch, Middleware).

%% @private
execute_and_finalize(Pipeline, Middleware, StartTime) ->
    Command = Pipeline#evoq_pipeline.command,
    Context = Pipeline#evoq_pipeline.context,

    %% Get or start the aggregate with the store_id from context
    AggregateType = Command#evoq_command.aggregate_type,
    AggregateId = Command#evoq_command.aggregate_id,
    StoreId = Context#evoq_execution_context.store_id,

    case evoq_aggregate_registry:get_or_start(AggregateType, AggregateId, StoreId) of
        {ok, Pid} ->
            execute_on_aggregate(Pipeline, Pid, Middleware, StartTime, Context);
        {error, Reason} ->
            handle_failure(Pipeline, {error, Reason}, Middleware, StartTime)
    end.

%% @private
execute_on_aggregate(Pipeline, Pid, Middleware, StartTime, Context) ->
    Command = Pipeline#evoq_pipeline.command,
    Waiter = open_waiter(Context),

    try evoq_aggregate:execute_command(Pid, Command) of
        {ok, Version, Events} = Result ->
            %% Success - run after_dispatch middleware
            Pipeline2 = evoq_middleware:assign(events, Events, Pipeline),
            Pipeline3 = evoq_middleware:assign(version, Version, Pipeline2),
            Pipeline4 = evoq_middleware:respond(Result, Pipeline3),
            Pipeline5 = evoq_middleware:chain(Pipeline4, after_dispatch, Middleware),

            %% Handle consistency
            FinalResult = handle_consistency(keep_response_if_erased(Pipeline5, Result),
                                             Context, Waiter, Version),
            emit_stop_telemetry(StartTime, Command, FinalResult),
            FinalResult;

        {error, wrong_expected_version} = Error ->
            %% Retry on version conflict
            maybe_retry(Pipeline, Error, Middleware, StartTime, Context);

        {error, _Reason} = Error ->
            handle_failure(Pipeline, Error, Middleware, StartTime)
    after
        close_waiter(Waiter)
    end.

%% @private
maybe_retry(Pipeline, Error, Middleware, StartTime, Context) ->
    case evoq_execution_context:retry(Context) of
        {ok, NewContext} ->
            %% Retry with updated context
            NewPipeline = Pipeline#evoq_pipeline{context = NewContext},
            Command = Pipeline#evoq_pipeline.command,
            AggregateType = Command#evoq_command.aggregate_type,
            AggregateId = Command#evoq_command.aggregate_id,
            StoreId = NewContext#evoq_execution_context.store_id,

            retry_on_aggregate(
                evoq_aggregate_registry:get_or_start(AggregateType, AggregateId, StoreId),
                NewPipeline, Pipeline, Middleware, StartTime, NewContext);

        {error, too_many_attempts} ->
            handle_failure(Pipeline, Error, Middleware, StartTime)
    end.

%% @private
retry_on_aggregate({ok, Pid}, NewPipeline, _Pipeline, Middleware, StartTime, NewContext) ->
    execute_on_aggregate(NewPipeline, Pid, Middleware, StartTime, NewContext);
retry_on_aggregate({error, Reason}, _NewPipeline, Pipeline, Middleware, StartTime, _NewContext) ->
    handle_failure(Pipeline, {error, Reason}, Middleware, StartTime).

%% @private
handle_failure(Pipeline, Error, Middleware, StartTime) ->
    Command = Pipeline#evoq_pipeline.command,

    Pipeline2 = evoq_middleware:assign(error, Error, Pipeline),
    Pipeline3 = evoq_middleware:respond(Error, Pipeline2),
    Pipeline4 = evoq_middleware:chain(Pipeline3, after_failure, Middleware),

    %% Emit exception telemetry
    Duration = evoq_telemetry:duration_since(StartTime),
    telemetry:execute(?TELEMETRY_DISPATCH_EXCEPTION, #{
        duration => Duration
    }, #{
        command_id => Command#evoq_command.command_id,
        error => Error
    }),

    evoq_middleware:get_response(keep_response_if_erased(Pipeline4, Error)).

%% @private
%% An after-stage halt may stop the chain; it may not erase a result the command
%% already produced (evoq#45).
%%
%% By the time `after_dispatch' or `after_failure' runs, the store has accepted
%% the command or refused it, and the router has already put that outcome on the
%% pipeline -- `{ok, Version, Events}' or the error. A middleware that halts and
%% leaves no response used to take the outcome away with it: the caller got
%% `undefined' for a command that ran, and `handle_consistency/4' saw nothing it
%% recognised, so a `strong' dispatch answered without waiting for a single
%% handler. The guarantee it asked for neither happened nor was refused.
%%
%% A middleware that DOES respond keeps its response: that is its decision to
%% make, the same rule the router applies to a halted `before_dispatch'
%% (evoq#41). Only an erased response is restored, and only with the outcome the
%% router itself put there.
keep_response_if_erased(Pipeline, Response) ->
    case evoq_middleware:get_response(Pipeline) of
        undefined -> evoq_middleware:respond(Response, Pipeline);
        _ -> Pipeline
    end.

%% @private Open the waiter BEFORE the append. An ack can only be sent to a
%% waiter that is already a member of the stream's group, and a handler can
%% finish before the router is back from the append: the window is small and
%% real. `eventual' opens nothing, so a dispatch that does not ask for a
%% guarantee pays nothing.
open_waiter(#evoq_execution_context{consistency = eventual}) ->
    undefined;
open_waiter(#evoq_execution_context{store_id = StoreId, aggregate_id = AggregateId}) ->
    evoq_consistency:open(StoreId, AggregateId).

%% @private
close_waiter(undefined) -> ok;
close_waiter(Waiter) -> evoq_consistency:close(Waiter).

%% @private
handle_consistency(Pipeline, Context, Waiter, Version) ->
    Response = evoq_middleware:get_response(Pipeline),
    Consistency = Context#evoq_execution_context.consistency,
    Timeout = Context#evoq_execution_context.timeout,

    case {Consistency, Response} of
        {eventual, _} ->
            Response;
        {_, {error, _}} ->
            Response;
        %% A DECLINED COMMAND HAS NOTHING TO BE CONSISTENT WITH. The sanctioned
        %% no-op (`execute/2' returning `{ok, []}', which is how a handler
        %% refuses a command it has already honoured) appends nothing, so
        %% `Version' is the stream's existing one and no handler will ever ack
        %% it for this dispatch. Waiting could only ever end in the timeout,
        %% answering `{error, consistency_timeout}' where the aggregate had said
        %% `{ok, Version, []}'. Same defect as evoq#16.
        {_, {ok, _, []}} ->
            Response;
        %% STRONG WAITS FOR THE HANDLERS THE APPENDED EVENTS REACH, derived
        %% from the registry the event router delivers by (evoq#23). Until
        %% evoq 1.29 it resolved to an empty set and answered at once. Each
        %% handler is required at the version of the event it was handed, so
        %% a two-event append whose events have different handlers waits for
        %% each at its own version (evoq 1.29.1, found in macula-realm#92).
        {strong, {ok, _, Appended}} ->
            First = Version - length(Appended) + 1,
            await(evoq_consistency:required(Appended, First), Waiter, Version, First,
                  Timeout, Response);
        {{handlers, Handlers}, {ok, _, Appended}} ->
            %% A named list is answered at the version the dispatch produced:
            %% the caller named the handlers, not the events, so there is no
            %% earlier version to hold them to.
            First = Version - length(Appended) + 1,
            await([{Handler, Version} || Handler <- Handlers], Waiter, Version, First,
                  Timeout, Response);
        _ ->
            Response
    end.

%% @private
await([], _Waiter, _Version, _First, _Timeout, Response) ->
    %% Nothing is subscribed to what was appended: there is no handler that
    %% could still be behind, which is an answer, not a timeout.
    Response;
await(Required, Waiter, Version, First, Timeout, Response) ->
    %% The append's own range of versions. A handler that dropped one of these
    %% events is a hole this dispatch must report, and one that dropped a
    %% later command's event says nothing about this one.
    consistency_outcome(
        evoq_consistency:await(Waiter, Required, Version,
                               #{timeout => Timeout, first_version => First}), Response).

%% @private Map a consistency wait outcome onto the response.
consistency_outcome(ok, Response) -> Response;
consistency_outcome({error, timeout}, _Response) -> {error, consistency_timeout};
%% A handler's own error policy dropped the event, so the write strong was
%% asked to wait for will never happen. Named: the caller needs to know which
%% handler, to decide between rebuilding its read model and fixing the cause.
consistency_outcome({error, {dropped, Handler}}, _Response) ->
    {error, {consistency_dropped, Handler}}.

%% @private
emit_stop_telemetry(StartTime, Command, Response) ->
    Duration = evoq_telemetry:duration_since(StartTime),
    EventCount = case Response of
        {ok, _, Events} -> length(Events);
        _ -> 0
    end,
    telemetry:execute(?TELEMETRY_DISPATCH_STOP, #{
        duration => Duration,
        event_count => EventCount
    }, #{
        command_id => Command#evoq_command.command_id,
        response => Response
    }).
