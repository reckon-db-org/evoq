# Architecture

evoq implements CQRS (Command Query Responsibility Segregation) and Event Sourcing patterns for Erlang applications. This guide explains the core architecture and how the components work together.

![Architecture Overview](assets/architecture.svg)

## Core Principles

### 1. Commands Produce Events, Events Update State

The fundamental flow in evoq:

1. **Command** arrives (user intent)
2. **Aggregate** validates and produces **Events** (facts)
3. Events are **persisted** to the event store
4. Events are **applied** to update aggregate state
5. Events are **routed** to subscribers (handlers, projections, process managers)

This separation ensures:
- Commands can be rejected (validation failed)
- Events are immutable facts (already happened)
- State can be rebuilt by replaying events

### 2. Read Models Are Separate From Write Models

CQRS separates:

| Write Side | Read Side |
|------------|-----------|
| Commands | Queries |
| Aggregates | Projections |
| Event Store | Read Models |
| Business logic | Optimized views |

Benefits:
- Read models can be denormalized for fast queries
- Each read model optimized for specific use case
- Read models can be rebuilt from events

### 3. Event Type Subscriptions (Not Stream-Based)

Unlike stream-based subscriptions, evoq routes events by **type**:

```erlang
%% Handler declares interest by event type
interested_in() ->
    [<<"OrderPlaced">>, <<"PaymentReceived">>].
```

Why this matters:
- 1 million orders = 1 million streams
- Stream subscriptions = 1 million subscriptions (memory explosion)
- Type subscriptions = ~10 event types (constant memory)

## Component Overview

### evoq_dispatcher

Entry point for command processing. Routes commands through the middleware pipeline to the target aggregate.

```erlang
%% Dispatch a command
{ok, Version, Events} = evoq_dispatcher:dispatch(Command).
```

### evoq_middleware

Pluggable pipeline for command processing:

```erlang
-behaviour(evoq_middleware).

before_dispatch(Pipeline) ->
    %% Validate, check idempotency, etc.
    {ok, Pipeline}.

after_dispatch(Pipeline) ->
    %% Post-processing
    {ok, Pipeline}.
```

Built-in middleware:
- **Validation** - Schema and business rule validation
- **Idempotency** - Prevent duplicate command processing
- **Consistency** - Strong or eventual consistency guarantees

### evoq_aggregate

Business logic container. Validates commands and produces events.

```erlang
-behaviour(evoq_aggregate).

%% Initialize state
init(AggregateId) -> {ok, InitialState}.

%% Validate and produce events
execute(State, Command) -> {ok, [Event]} | {error, Reason}.

%% Update state from event
apply(State, Event) -> NewState.
```

### evoq_event_router

Routes persisted events to interested subscribers by event type.

Subscribers:
- Event Handlers (side effects)
- Process Managers (orchestration)
- Projections (read models)

### evoq_event_handler

React to events with side effects:

```erlang
-behaviour(evoq_event_handler).

interested_in() -> [<<"UserRegistered">>].

handle_event(EventType, Event, Metadata, State) ->
    send_welcome_email(Event),
    {ok, State}.
```

Features:
- Retry strategies (exponential backoff)
- Dead letter queue for failed events
- Checkpoint-based recovery

### evoq_process_manager

Coordinate long-running business processes (sagas):

```erlang
-behaviour(evoq_process_manager).

interested_in() -> [<<"OrderPlaced">>, <<"PaymentReceived">>].

correlate(Event, _Meta) ->
    {continue, maps:get(order_id, Event)}.

handle(State, Event, _Meta) ->
    Cmd = create_next_command(Event),
    {ok, State, [Cmd]}.

compensate(State, FailedCommand) ->
    {ok, [create_rollback_command(FailedCommand)]}.
```

### evoq_projection

Build read models from events:

```erlang
-behaviour(evoq_projection).

interested_in() -> [<<"OrderPlaced">>, <<"OrderShipped">>].

project(Event, Metadata, State, ReadModel) ->
    Updated = update_order_summary(Event, ReadModel),
    {ok, State, Updated}.
```

## Data Flow

### Command Processing

![Command Dispatch](assets/command-dispatch.svg)

1. Client creates command via `evoq_command:new/4`
2. Dispatcher routes through middleware pipeline
3. Aggregate executes command, produces events
4. Events persisted to reckon-db
5. Result returned to client

### Event Distribution

![Event Routing](assets/event-routing.svg)

1. Events persisted to event store
2. Event router receives notification
3. Router looks up subscribers by event type
4. Events delivered to matching handlers

## Supervision Tree

```
evoq_sup
├── evoq_aggregates_sup           # Dynamic aggregate supervisors
│   ├── evoq_aggregate_partition_sup_0
│   │   └── evoq_aggregate (bank_account, "acc-1")
│   │   └── evoq_aggregate (bank_account, "acc-2")
│   ├── evoq_aggregate_partition_sup_1
│   │   └── ...
│   └── ... (4 partitions by default)
├── evoq_event_handler_sup        # Event handlers
│   └── evoq_event_handler (email_handler)
│   └── evoq_event_handler (audit_handler)
├── evoq_process_manager_sup      # Process managers
│   └── evoq_process_manager (order_pm, "order-123")
├── evoq_projection_sup           # Projections
│   └── evoq_projection (order_summary)
├── evoq_memory_monitor           # Memory pressure monitoring
└── evoq_event_router             # Event type registry
```

### Partitioned Supervision

Aggregates are distributed across 4 partition supervisors using consistent hashing. This prevents:
- Single supervisor bottleneck
- Cascade failures affecting all aggregates
- Uneven load distribution

## Integration with reckon-db

evoq uses reckon-db for event persistence:

```erlang
%% Event store operations delegated to reckon-db
evoq_event_store:append(StoreId, StreamId, ExpectedVersion, Events)
evoq_event_store:read(StoreId, StreamId, StartVersion, Count)
evoq_event_store:subscribe(StoreId, EventTypes, Handler)
```

The adapter pattern allows different backends:

```erlang
%% Configure adapter in sys.config
{evoq, [
    {event_store_adapter, evoq_esdb_adapter}
]}
```

## Next Steps

- [Aggregates Guide](aggregates.md) - Deep dive into aggregate patterns
- [Event Handlers Guide](event_handlers.md) - Building reactive systems
- [Process Managers Guide](process_managers.md) - Orchestrating workflows
- [Projections Guide](projections.md) - Building read models
