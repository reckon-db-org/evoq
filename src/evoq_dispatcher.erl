%% @doc Command dispatcher with middleware pipeline.
%%
%% Dispatches commands through the middleware chain to aggregates.
%% Supports idempotency, retries, and consistency guarantees.
%%
%% == Dispatch Flow ==
%%
%% 1. Check idempotency cache
%% 2. Create execution context
%% 3. Run before_dispatch middleware
%% 4. Get or start aggregate
%% 5. Execute command on aggregate
%% 6. Run after_dispatch or after_failure middleware
%% 7. Handle consistency (wait for handlers if strong)
%% 8. Cache result for idempotency
%%
%% @author rgfaber
-module(evoq_dispatcher).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([dispatch/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Dispatch a command through the middleware pipeline.
%%
%% If command_id is undefined, auto-generates one.
%% If idempotency_key is set, uses it for deduplication cache.
%% Otherwise, command_id is used (each dispatch is unique).
-spec dispatch(#evoq_command{}, map()) -> {ok, non_neg_integer(), [map()]} | {error, term()}.
dispatch(Command0, Opts) ->
    %% Auto-generate command_id if not provided
    Command = evoq_command:ensure_id(Command0),
    TTL = application:get_env(evoq, idempotency_ttl, ?DEFAULT_IDEMPOTENCY_TTL),

    %% Use idempotency_key for cache if provided, otherwise command_id
    CacheKey = case Command#evoq_command.idempotency_key of
        undefined -> Command#evoq_command.command_id;
        Key -> Key
    end,

    evoq_idempotency:check_and_store(CacheKey, fun() ->
        dispatch_internal(Command, Opts)
    end, TTL).

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
dispatch_internal(Command, Opts) ->
    StartTime = erlang:system_time(microsecond),

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
        system_time => StartTime
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
            Response = evoq_middleware:get_response(Pipeline2),
            emit_stop_telemetry(StartTime, Command, Response),
            Response;
        false ->
            %% Execute the command
            execute_and_finalize(Pipeline2, Middleware, StartTime)
    end.

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

    case evoq_aggregate:execute_command(Pid, Command) of
        {ok, Version, Events} = Result ->
            %% Success - run after_dispatch middleware
            Pipeline2 = evoq_middleware:assign(events, Events, Pipeline),
            Pipeline3 = evoq_middleware:assign(version, Version, Pipeline2),
            Pipeline4 = evoq_middleware:respond(Result, Pipeline3),
            Pipeline5 = evoq_middleware:chain(Pipeline4, after_dispatch, Middleware),

            %% Handle consistency
            FinalResult = handle_consistency(Pipeline5, Context),
            emit_stop_telemetry(StartTime, Command, FinalResult),
            FinalResult;

        {error, wrong_expected_version} = Error ->
            %% Retry on version conflict
            maybe_retry(Pipeline, Error, Middleware, StartTime, Context);

        {error, _Reason} = Error ->
            handle_failure(Pipeline, Error, Middleware, StartTime)
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

            case evoq_aggregate_registry:get_or_start(AggregateType, AggregateId, StoreId) of
                {ok, Pid} ->
                    execute_on_aggregate(NewPipeline, Pid, Middleware, StartTime, NewContext);
                {error, Reason} ->
                    handle_failure(Pipeline, {error, Reason}, Middleware, StartTime)
            end;

        {error, too_many_attempts} ->
            handle_failure(Pipeline, Error, Middleware, StartTime)
    end.

%% @private
handle_failure(Pipeline, Error, Middleware, StartTime) ->
    Command = Pipeline#evoq_pipeline.command,

    Pipeline2 = evoq_middleware:assign(error, Error, Pipeline),
    Pipeline3 = evoq_middleware:respond(Error, Pipeline2),
    Pipeline4 = evoq_middleware:chain(Pipeline3, after_failure, Middleware),

    %% Emit exception telemetry
    Duration = erlang:system_time(microsecond) - StartTime,
    telemetry:execute(?TELEMETRY_DISPATCH_EXCEPTION, #{
        duration => Duration
    }, #{
        command_id => Command#evoq_command.command_id,
        error => Error
    }),

    evoq_middleware:get_response(Pipeline4).

%% @private
handle_consistency(Pipeline, Context) ->
    Response = evoq_middleware:get_response(Pipeline),
    Consistency = Context#evoq_execution_context.consistency,
    StoreId = Context#evoq_execution_context.store_id,

    case {Consistency, Response} of
        {eventual, _} ->
            Response;
        {_, {error, _}} ->
            Response;
        {strong, {ok, Version, _Events}} ->
            AggregateId = Context#evoq_execution_context.aggregate_id,
            case evoq_consistency:wait_for(StoreId, AggregateId, Version, #{}) of
                ok -> Response;
                {error, timeout} -> {error, consistency_timeout}
            end;
        {{handlers, Handlers}, {ok, Version, _Events}} ->
            AggregateId = Context#evoq_execution_context.aggregate_id,
            case evoq_consistency:wait_for(StoreId, AggregateId, Version, #{handlers => Handlers}) of
                ok -> Response;
                {error, timeout} -> {error, consistency_timeout}
            end;
        _ ->
            Response
    end.

%% @private
emit_stop_telemetry(StartTime, Command, Response) ->
    Duration = erlang:system_time(microsecond) - StartTime,
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
