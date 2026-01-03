%% @doc Telemetry event definitions for evoq.
%%
%% All telemetry events follow the pattern:
%% [evoq, component, action, stage]
%%
%% Where stage is: start | stop | exception
%%
%% @author rgfaber

-ifndef(EVOQ_TELEMETRY_HRL).
-define(EVOQ_TELEMETRY_HRL, true).

%%====================================================================
%% Aggregate Telemetry Events
%%====================================================================

%% Command execution
-define(TELEMETRY_AGGREGATE_EXECUTE_START, [evoq, aggregate, execute, start]).
-define(TELEMETRY_AGGREGATE_EXECUTE_STOP, [evoq, aggregate, execute, stop]).
-define(TELEMETRY_AGGREGATE_EXECUTE_EXCEPTION, [evoq, aggregate, execute, exception]).

%% Aggregate lifecycle
-define(TELEMETRY_AGGREGATE_INIT, [evoq, aggregate, init]).
-define(TELEMETRY_AGGREGATE_HIBERNATE, [evoq, aggregate, hibernate]).
-define(TELEMETRY_AGGREGATE_PASSIVATE, [evoq, aggregate, passivate]).
-define(TELEMETRY_AGGREGATE_ACTIVATE, [evoq, aggregate, activate]).

%% Snapshot operations
-define(TELEMETRY_AGGREGATE_SNAPSHOT_SAVE, [evoq, aggregate, snapshot, save]).
-define(TELEMETRY_AGGREGATE_SNAPSHOT_LOAD, [evoq, aggregate, snapshot, load]).

%%====================================================================
%% Command Dispatch Telemetry Events
%%====================================================================

-define(TELEMETRY_DISPATCH_START, [evoq, dispatch, start]).
-define(TELEMETRY_DISPATCH_STOP, [evoq, dispatch, stop]).
-define(TELEMETRY_DISPATCH_EXCEPTION, [evoq, dispatch, exception]).

%% Middleware
-define(TELEMETRY_MIDDLEWARE_BEFORE, [evoq, middleware, before_dispatch]).
-define(TELEMETRY_MIDDLEWARE_AFTER, [evoq, middleware, after_dispatch]).
-define(TELEMETRY_MIDDLEWARE_FAILURE, [evoq, middleware, failure]).

%% Idempotency
-define(TELEMETRY_IDEMPOTENCY_HIT, [evoq, idempotency, hit]).
-define(TELEMETRY_IDEMPOTENCY_MISS, [evoq, idempotency, miss]).

%%====================================================================
%% Event Handler Telemetry Events
%%====================================================================

-define(TELEMETRY_HANDLER_START, [evoq, handler, start]).
-define(TELEMETRY_HANDLER_STOP, [evoq, handler, stop]).
-define(TELEMETRY_HANDLER_EXCEPTION, [evoq, handler, exception]).
-define(TELEMETRY_HANDLER_EVENT_START, [evoq, handler, event, start]).
-define(TELEMETRY_HANDLER_EVENT_STOP, [evoq, handler, event, stop]).
-define(TELEMETRY_HANDLER_EVENT_EXCEPTION, [evoq, handler, event, exception]).

%% Retry and dead letter
-define(TELEMETRY_HANDLER_RETRY, [evoq, handler, retry]).
-define(TELEMETRY_HANDLER_DEAD_LETTER, [evoq, handler, dead_letter]).

%%====================================================================
%% Event Routing Telemetry Events
%%====================================================================

-define(TELEMETRY_ROUTING_EVENT, [evoq, router, event]).
-define(TELEMETRY_ROUTING_UPCAST, [evoq, router, upcast]).

%%====================================================================
%% Process Manager Telemetry Events
%%====================================================================

-define(TELEMETRY_PM_START, [evoq, process_manager, start]).
-define(TELEMETRY_PM_STOP, [evoq, process_manager, stop]).
-define(TELEMETRY_PM_COMMAND, [evoq, process_manager, command]).
-define(TELEMETRY_PM_COMPENSATE, [evoq, process_manager, compensate]).

%%====================================================================
%% Projection Telemetry Events
%%====================================================================

-define(TELEMETRY_PROJECTION_START, [evoq, projection, start]).
-define(TELEMETRY_PROJECTION_STOP, [evoq, projection, stop]).
-define(TELEMETRY_PROJECTION_EVENT, [evoq, projection, event]).
-define(TELEMETRY_PROJECTION_EXCEPTION, [evoq, projection, exception]).
-define(TELEMETRY_PROJECTION_CHECKPOINT, [evoq, projection, checkpoint]).

%%====================================================================
%% Memory Monitor Telemetry Events
%%====================================================================

-define(TELEMETRY_MEMORY_PRESSURE, [evoq, memory, pressure]).
-define(TELEMETRY_MEMORY_TTL_ADJUSTED, [evoq, memory, ttl_adjusted]).

-endif. %% EVOQ_TELEMETRY_HRL
