# evoq
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-support-yellow.svg)](https://buymeacoffee.com/beamologist)

Erlang CQRS/Event Sourcing framework built on reckon-db.

![Architecture Overview](assets/architecture.svg)

## Features

- Aggregate lifecycle with configurable TTL and passivation
- Per-event-type subscriptions (not per-stream)
- Command idempotency
- Middleware pipeline for command dispatch
- Event handlers with retry strategies and dead letter support
- Process managers (sagas) with compensation
- Projections with checkpointing
- Schema evolution via event upcasters
- Memory pressure monitoring with adaptive TTL
- Comprehensive telemetry integration

## Installation

Add to your `rebar.config`:

```erlang
{deps, [
    {evoq, "1.0.0"}
]}.
```

## Quick Start

### Defining an Aggregate

```erlang
-module(bank_account).
-behaviour(evoq_aggregate).

-export([init/1, execute/2, apply/2]).

init(_AccountId) ->
    {ok, #{balance => 0, status => active}}.

execute(#{status := closed}, _Command) ->
    {error, account_closed};
execute(_State, #{command_type := open_account, initial_balance := B}) ->
    {ok, [#{event_type => <<"AccountOpened">>, data => #{balance => B}}]};
execute(#{balance := Bal}, #{command_type := deposit, amount := A}) ->
    {ok, [#{event_type => <<"MoneyDeposited">>, data => #{amount => A}}]}.

apply(State, #{event_type := <<"AccountOpened">>, data := #{balance := B}}) ->
    State#{balance => B};
apply(#{balance := B} = State, #{event_type := <<"MoneyDeposited">>, data := #{amount := A}}) ->
    State#{balance => B + A}.
```

### Dispatching Commands

```erlang
%% Create a command
Command = evoq_command:new(
    deposit,           %% command type
    bank_account,      %% aggregate module
    <<"acc-123">>,     %% aggregate id
    #{amount => 100}   %% payload
),

%% Dispatch it
{ok, Version, Events} = evoq_router:dispatch(Command).
```

### Event Handlers

```erlang
-module(notification_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() ->
    [<<"AccountOpened">>, <<"LargeDeposit">>].

init(_Config) ->
    {ok, #{}}.

handle_event(<<"AccountOpened">>, Event, _Metadata, State) ->
    send_welcome_email(Event),
    {ok, State};
handle_event(<<"LargeDeposit">>, Event, _Metadata, State) ->
    send_deposit_alert(Event),
    {ok, State}.
```

### Process Managers (Sagas)

```erlang
-module(order_fulfillment_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2]).

interested_in() ->
    [<<"OrderPlaced">>, <<"PaymentReceived">>, <<"ItemShipped">>].

correlate(#{data := #{order_id := OrderId}}, _Meta) ->
    {continue, OrderId}.

handle(State, #{event_type := <<"OrderPlaced">>} = Event, _Meta) ->
    Cmd = evoq_command:new(process_payment, payment, OrderId, #{}),
    {ok, State, [Cmd]};
handle(State, #{event_type := <<"PaymentReceived">>}, _Meta) ->
    Cmd = evoq_command:new(ship_item, shipping, OrderId, #{}),
    {ok, State, [Cmd]};
handle(State, #{event_type := <<"ItemShipped">>}, _Meta) ->
    {ok, State#{status => completed}}.

apply(State, _Event) ->
    State.
```

### Projections

```erlang
-module(account_summary_projection).
-behaviour(evoq_projection).

-export([interested_in/0, init/1, project/4]).

interested_in() ->
    [<<"AccountOpened">>, <<"MoneyDeposited">>, <<"MoneyWithdrawn">>].

init(_Config) ->
    {ok, ReadModel} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, #{}, ReadModel}.

project(#{event_type := <<"AccountOpened">>, data := #{balance := B}},
        #{aggregate_id := Id}, State, ReadModel) ->
    {ok, NewRM} = evoq_read_model:put(Id, #{balance => B, tx_count => 0}, ReadModel),
    {ok, State, NewRM};
project(#{event_type := <<"MoneyDeposited">>, data := #{amount := A}},
        #{aggregate_id := Id}, State, ReadModel) ->
    {ok, Current} = evoq_read_model:get(Id, ReadModel),
    Updated = Current#{
        balance => maps:get(balance, Current) + A,
        tx_count => maps:get(tx_count, Current) + 1
    },
    {ok, NewRM} = evoq_read_model:put(Id, Updated, ReadModel),
    {ok, State, NewRM}.
```

## Core Behaviors

### evoq_aggregate

Aggregates maintain business invariants and produce events.

```erlang
-callback init(AggregateId :: binary()) -> {ok, State :: term()}.
-callback execute(State :: term(), Command :: map()) ->
    {ok, [Event :: map()]} | {error, Reason :: term()}.
-callback apply(State :: term(), Event :: map()) -> NewState :: term().

%% Optional: snapshotting
-callback snapshot(State :: term()) -> SnapshotData :: term().
-callback from_snapshot(SnapshotData :: term()) -> State :: term().
```

### evoq_aggregate_lifespan

Controls aggregate lifecycle (TTL, passivation).

```erlang
-callback after_event(Event :: map()) -> timeout() | infinity | hibernate | stop.
-callback after_command(Command :: map()) -> timeout() | infinity | hibernate | stop.
-callback after_error(Error :: term()) -> timeout() | infinity | hibernate | stop.
-callback on_timeout(State :: term()) -> {ok, action()} | {snapshot, action()}.
```

Default: 30-minute idle timeout, snapshot on passivation.

### evoq_event_handler

Subscribe to events by type (not by stream).

```erlang
-callback interested_in() -> [EventType :: binary()].
-callback init(Config :: map()) -> {ok, State :: term()}.
-callback handle_event(EventType, Event, Metadata, State) ->
    {ok, NewState} | {error, Reason}.
```

### evoq_process_manager

Coordinate long-running business processes (sagas).

```erlang
-callback interested_in() -> [EventType :: binary()].
-callback correlate(Event, Metadata) -> {start | continue | stop, ProcessId} | false.
-callback handle(State, Event, Metadata) -> {ok, State} | {ok, State, [Command]}.
-callback apply(State, Event) -> NewState.

%% Optional: saga compensation
-callback compensate(State, FailedCommand) -> {ok, [CompensatingCommand]} | skip.
```

### evoq_projection

Build read models from events.

```erlang
-callback interested_in() -> [EventType :: binary()].
-callback init(Config) -> {ok, State, ReadModel}.
-callback project(Event, Metadata, State, ReadModel) ->
    {ok, NewState, NewReadModel} | {skip, State, ReadModel}.
```

### evoq_middleware

Intercept command dispatch.

```erlang
-callback before_dispatch(Pipeline) -> {ok, Pipeline} | {error, Reason}.
-callback after_dispatch(Pipeline) -> {ok, Pipeline}.
-callback on_failure(Pipeline, Reason) -> {ok, Pipeline} | {error, Reason}.
```

## Configuration

```erlang
%% sys.config
[{evoq, [
    {store_id, my_store},

    {aggregate_defaults, #{
        idle_timeout => 1800000,    %% 30 minutes
        hibernate_after => 60000,   %% 1 minute
        snapshot_every => 100       %% events
    }},

    {aggregate_partitions, 4},

    {memory_monitor, #{
        check_interval => 10000,    %% 10 seconds
        elevated_threshold => 0.70,
        critical_threshold => 0.85
    }},

    {handler_defaults, #{
        consistency => eventual,
        start_from => origin
    }}
]}].
```

## Memory Pressure Handling

The memory monitor adjusts aggregate TTLs based on system memory usage:

| Pressure Level | Memory Usage | TTL Factor |
|----------------|--------------|------------|
| normal         | < 70%        | 1.0x       |
| elevated       | 70-85%       | 0.5x       |
| critical       | > 85%        | 0.1x       |

## Telemetry Events

All events follow the pattern: `[evoq, component, action, stage]`

### Aggregate Events
- `[evoq, aggregate, execute, start | stop | exception]`
- `[evoq, aggregate, init | hibernate | passivate | activate]`
- `[evoq, aggregate, snapshot, save | load]`

### Handler Events
- `[evoq, handler, start | stop | exception]`
- `[evoq, handler, event, start | stop | exception]`
- `[evoq, handler, retry | dead_letter]`

### Process Manager Events
- `[evoq, process_manager, start | stop]`
- `[evoq, process_manager, command | compensate]`

### Projection Events
- `[evoq, projection, start | stop | exception]`
- `[evoq, projection, event | checkpoint]`

## Testing

```bash
# Unit tests
rebar3 eunit --dir=test/unit

# Integration tests
rebar3 ct

# Dialyzer
rebar3 dialyzer

# All tests with coverage
rebar3 do eunit, ct, cover
```

## Key Design Decisions

### Per-Event-Type Subscriptions

Unlike stream-based subscriptions, evoq subscribes by event type. This prevents subscription explosion when you have millions of aggregates.

### Default TTL (Not Infinity!)

Aggregates have a 30-minute default idle timeout. This prevents unbounded memory growth that occurs with infinite lifespan defaults.

### Partitioned Supervision

Aggregates are distributed across 4 partition supervisors using consistent hashing, preventing single-supervisor bottlenecks.

## Documentation

Comprehensive guides are available:

- [Architecture Overview](guides/architecture.md) - How the components work together
- [Aggregates](guides/aggregates.md) - Building domain models with event sourcing
- [Event Handlers](guides/event_handlers.md) - Reacting to events with side effects
- [Process Managers](guides/process_managers.md) - Coordinating long-running workflows
- [Projections](guides/projections.md) - Building optimized read models
- [Adapters](guides/adapters.md) - Integrating with different event stores

## License

Apache-2.0
