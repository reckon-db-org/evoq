%% @doc Core records for evoq CQRS/Event Sourcing framework.
%%
%% @author rgfaber

-ifndef(EVOQ_HRL).
-define(EVOQ_HRL, true).

%%====================================================================
%% Default Configuration
%%====================================================================

-define(DEFAULT_IDLE_TIMEOUT, 1800000).     %% 30 minutes
-define(DEFAULT_HIBERNATE_AFTER, 60000).    %% 1 minute
-define(DEFAULT_SNAPSHOT_EVERY, 100).       %% events
-define(DEFAULT_RETRY_ATTEMPTS, 10).
-define(DEFAULT_TIMEOUT, 5000).             %% 5 seconds
-define(DEFAULT_IDEMPOTENCY_TTL, 3600000).  %% 1 hour

%%====================================================================
%% Command Record
%%====================================================================

%% @doc Command structure for dispatching to aggregates.
%%
%% Fields:
%% - command_id: Unique identifier for tracing (auto-generated if undefined)
%% - command_type: Atom identifying the command type
%% - aggregate_type: Module implementing evoq_aggregate behavior
%% - aggregate_id: Unique identifier for the aggregate instance
%% - payload: Command-specific data
%% - metadata: Additional context (user_id, tenant_id, etc.)
%% - causation_id: ID of the command/event that caused this
%% - correlation_id: ID linking related commands/events
%% - idempotency_key: Optional caller-provided key for deduplication.
%%   When set, this key is used for the idempotency cache instead of
%%   command_id. Use this for deterministic deduplication (e.g. "user
%%   cannot submit the same form twice"). When undefined, command_id
%%   is used (each dispatch is unique).
-record(evoq_command, {
    command_id :: binary() | undefined,
    command_type :: atom() | undefined,
    aggregate_type :: atom() | undefined,
    aggregate_id :: binary() | undefined,
    payload = #{} :: map(),
    metadata = #{} :: map(),
    causation_id :: binary() | undefined,
    correlation_id :: binary() | undefined,
    idempotency_key :: binary() | undefined
}).

-type evoq_command() :: #evoq_command{}.

%%====================================================================
%% Aggregate State Record
%%====================================================================

%% @doc Internal state wrapper for aggregate GenServers.
%%
%% Tracks the aggregate module, domain state, version, and lifespan
%% configuration. Used internally by evoq_aggregate GenServer.
-record(evoq_aggregate_state, {
    stream_id :: binary(),
    aggregate_module :: atom(),
    store_id :: atom(),
    state :: term(),
    version = 0 :: non_neg_integer(),
    lifespan_module :: atom(),
    last_activity :: integer(),
    snapshot_count = 0 :: non_neg_integer()
}).

-type evoq_aggregate_state() :: #evoq_aggregate_state{}.

%%====================================================================
%% Execution Context Record
%%====================================================================

%% @doc Tracks command execution through the dispatch pipeline.
%%
%% Contains retry state, consistency requirements, and metadata
%% that flows through middleware and aggregate execution.
-record(evoq_execution_context, {
    command_id :: binary(),
    causation_id :: binary() | undefined,
    correlation_id :: binary() | undefined,
    aggregate_id :: binary(),
    aggregate_type :: atom(),
    store_id :: atom(),
    expected_version = -1 :: integer(),
    retry_attempts = ?DEFAULT_RETRY_ATTEMPTS :: non_neg_integer(),
    consistency = eventual :: eventual | strong | {handlers, [atom()]},
    timeout = ?DEFAULT_TIMEOUT :: pos_integer(),
    metadata = #{} :: map()
}).

-type evoq_execution_context() :: #evoq_execution_context{}.

%%====================================================================
%% Handler State Record
%%====================================================================

%% @doc Internal state for event handler workers.
-record(evoq_handler_state, {
    handler_module :: atom(),
    event_types :: [binary()],
    checkpoint = 0 :: non_neg_integer(),
    handler_state :: term(),
    consistency = eventual :: eventual | strong
}).

-type evoq_handler_state() :: #evoq_handler_state{}.

%%====================================================================
%% Failure Context Record
%%====================================================================

%% @doc Tracks failure state across retry attempts.
%%
%% Provides context for error handlers to make retry/skip/stop decisions.
-record(evoq_failure_context, {
    handler_module :: atom(),
    event :: map(),
    error :: term(),
    attempt_number = 1 :: pos_integer(),
    first_failure_at :: integer(),
    last_failure_at :: integer(),
    stacktrace = [] :: list()
}).

-type evoq_failure_context() :: #evoq_failure_context{}.

%%====================================================================
%% Dead Letter Record
%%====================================================================

%% @doc Entry for events that failed processing after all retries.
-record(evoq_dead_letter, {
    id :: binary(),
    event :: map(),
    handler_module :: atom(),
    error :: term(),
    failure_context :: #evoq_failure_context{},
    created_at :: integer()
}).

-type evoq_dead_letter() :: #evoq_dead_letter{}.

%%====================================================================
%% Middleware Pipeline Record
%%====================================================================

%% @doc State flowing through the middleware pipeline.
%%
%% Middleware can:
%% - Add data to assigns
%% - Halt the pipeline
%% - Set the response
-record(evoq_pipeline, {
    command :: #evoq_command{},
    context :: #evoq_execution_context{},
    assigns = #{} :: map(),
    halted = false :: boolean(),
    response :: term()
}).

-type evoq_pipeline() :: #evoq_pipeline{}.

%%====================================================================
%% Process Manager State Record
%%====================================================================

%% @doc Internal state for process manager instances.
-record(evoq_pm_state, {
    pm_module :: atom(),
    process_id :: binary(),
    state :: term(),
    pending_commands = [] :: [#evoq_command{}],
    last_event_number = 0 :: non_neg_integer()
}).

-type evoq_pm_state() :: #evoq_pm_state{}.

-endif. %% EVOQ_HRL
