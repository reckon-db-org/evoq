# Process Managers

Process managers (also called sagas) coordinate long-running business processes that span multiple aggregates. They react to events and dispatch commands to drive workflows forward.

![Process Manager Flow](assets/process-manager.svg)

## When to Use Process Managers

Use process managers when:

- A business process spans **multiple aggregates**
- You need to **coordinate** a sequence of operations
- Failures require **compensation** (rollback)
- The process has **state** that persists across events

Examples:
- Order fulfillment (payment → inventory → shipping)
- User onboarding (account → profile → welcome email)
- Money transfer (debit source → credit destination)

## Basic Process Manager

```erlang
-module(order_fulfillment_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2]).

%% Events this process manager reacts to
interested_in() ->
    [<<"OrderPlaced">>, <<"PaymentReceived">>, <<"InventoryReserved">>, <<"ItemShipped">>].

%% Route events to the correct process instance
correlate(#{data := #{order_id := OrderId}}, _Metadata) ->
    {continue, OrderId}.

%% React to events by dispatching commands
handle(State, #{event_type := <<"OrderPlaced">>} = Event, _Meta) ->
    OrderId = maps:get(order_id, maps:get(data, Event)),
    Amount = maps:get(amount, maps:get(data, Event)),

    %% Dispatch command to payment aggregate
    Cmd = evoq_command:new(process_payment, payment, OrderId, #{amount => Amount}),
    {ok, State#{status => awaiting_payment}, [Cmd]};

handle(State, #{event_type := <<"PaymentReceived">>}, _Meta) ->
    OrderId = maps:get(order_id, State),

    %% Dispatch command to inventory aggregate
    Cmd = evoq_command:new(reserve_inventory, inventory, OrderId, #{}),
    {ok, State#{status => awaiting_inventory}, [Cmd]};

handle(State, #{event_type := <<"InventoryReserved">>}, _Meta) ->
    OrderId = maps:get(order_id, State),

    %% Dispatch command to shipping aggregate
    Cmd = evoq_command:new(ship_item, shipping, OrderId, #{}),
    {ok, State#{status => awaiting_shipment}, [Cmd]};

handle(State, #{event_type := <<"ItemShipped">>}, _Meta) ->
    %% Process complete
    {ok, State#{status => completed}}.

%% Update process state from events
apply(State, #{event_type := <<"OrderPlaced">>, data := Data}) ->
    State#{
        order_id => maps:get(order_id, Data),
        customer_id => maps:get(customer_id, Data),
        items => maps:get(items, Data),
        status => started
    };
apply(State, _Event) ->
    State.
```

## Required Callbacks

### interested_in/0

Declare which event types this process manager reacts to:

```erlang
-spec interested_in() -> [EventType :: binary()].

interested_in() ->
    [<<"OrderPlaced">>, <<"PaymentFailed">>, <<"InventoryUnavailable">>].
```

### correlate/2

Route events to the correct process instance:

```erlang
-spec correlate(Event :: map(), Metadata :: map()) ->
    {start, ProcessId :: term()} |
    {continue, ProcessId :: term()} |
    {stop, ProcessId :: term()} |
    false.

%% Start a new process
correlate(#{event_type := <<"OrderPlaced">>, data := #{order_id := OrderId}}, _Meta) ->
    {start, OrderId};

%% Continue existing process
correlate(#{event_type := <<"PaymentReceived">>, data := #{order_id := OrderId}}, _Meta) ->
    {continue, OrderId};

%% Stop the process
correlate(#{event_type := <<"OrderCancelled">>, data := #{order_id := OrderId}}, _Meta) ->
    {stop, OrderId};

%% Ignore event (no matching process)
correlate(_, _) ->
    false.
```

### handle/3

React to events and optionally dispatch commands:

```erlang
-spec handle(State :: term(), Event :: map(), Metadata :: map()) ->
    {ok, NewState :: term()} |
    {ok, NewState :: term(), Commands :: [map()]}.

%% Just update state
handle(State, #{event_type := <<"OrderPlaced">>}, _Meta) ->
    {ok, State#{started_at => erlang:system_time()}};

%% Update state and dispatch commands
handle(State, #{event_type := <<"PaymentReceived">>}, _Meta) ->
    Cmd1 = evoq_command:new(reserve_inventory, inventory, OrderId, #{}),
    Cmd2 = evoq_command:new(notify_warehouse, warehouse, OrderId, #{}),
    {ok, State#{payment_received => true}, [Cmd1, Cmd2]}.
```

### apply/2

Update process state from events (called before `handle/3`):

```erlang
-spec apply(State :: term(), Event :: map()) -> NewState :: term().

apply(State, #{event_type := <<"OrderPlaced">>, data := Data}) ->
    State#{
        order_id => maps:get(order_id, Data),
        total => maps:get(total, Data)
    };
apply(State, #{event_type := <<"PaymentReceived">>, data := #{amount := Amount}}) ->
    State#{paid_amount => Amount}.
```

## Compensation (Rollback)

When a step fails, the process manager can compensate by undoing previous steps:

```erlang
-module(money_transfer_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2, compensate/2]).

interested_in() ->
    [<<"TransferInitiated">>, <<"SourceDebited">>, <<"DestinationCreditFailed">>].

handle(State, #{event_type := <<"TransferInitiated">>}, _Meta) ->
    %% Step 1: Debit source account
    Cmd = evoq_command:new(debit, account, SourceId, #{amount => Amount}),
    {ok, State#{status => debiting_source}, [Cmd]};

handle(State, #{event_type := <<"SourceDebited">>}, _Meta) ->
    %% Step 2: Credit destination account
    Cmd = evoq_command:new(credit, account, DestId, #{amount => Amount}),
    {ok, State#{status => crediting_dest}, [Cmd]};

handle(State, #{event_type := <<"DestinationCreditFailed">>}, _Meta) ->
    %% Credit failed - need to compensate
    {ok, State#{status => compensating}}.

%% Compensation callback
-spec compensate(State :: term(), FailedCommand :: map()) ->
    {ok, CompensatingCommands :: [map()]} | skip.

compensate(#{source_id := SourceId, amount := Amount}, #{command_type := credit}) ->
    %% Credit failed, refund the source account
    RefundCmd = evoq_command:new(credit, account, SourceId, #{
        amount => Amount,
        reason => <<"transfer_failed">>
    }),
    {ok, [RefundCmd]};

compensate(_, _) ->
    skip.
```

## State Machine Pattern

Process managers naturally model state machines:

```erlang
-module(order_state_machine_pm).

%% State transitions
handle(#{status := new} = State, #{event_type := <<"OrderPlaced">>}, _) ->
    {ok, State#{status => awaiting_payment}, [process_payment_cmd()]};

handle(#{status := awaiting_payment} = State, #{event_type := <<"PaymentReceived">>}, _) ->
    {ok, State#{status => awaiting_shipment}, [ship_order_cmd()]};

handle(#{status := awaiting_payment} = State, #{event_type := <<"PaymentFailed">>}, _) ->
    {ok, State#{status => cancelled}, [notify_customer_cmd()]};

handle(#{status := awaiting_shipment} = State, #{event_type := <<"ItemShipped">>}, _) ->
    {ok, State#{status => completed}};

%% Invalid transition - ignore
handle(State, _Event, _Meta) ->
    {ok, State}.
```

## Timeout Handling

Handle timeouts for long-running processes:

```erlang
-module(booking_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2, timeout/0]).

timeout() ->
    15 * 60 * 1000.  %% 15 minute timeout

handle(#{status := awaiting_confirmation, started_at := Started} = State, timeout, _Meta) ->
    %% Timeout triggered - cancel the booking
    Cmd = evoq_command:new(cancel_booking, booking, BookingId, #{
        reason => timeout
    }),
    {ok, State#{status => timed_out}, [Cmd]}.
```

## Correlation Strategies

### By Entity ID

Most common - route by the main entity:

```erlang
correlate(#{data := #{order_id := OrderId}}, _) ->
    {continue, OrderId}.
```

### By Correlation ID

Use metadata for cross-aggregate correlation:

```erlang
correlate(_Event, #{correlation_id := CorrelationId}) ->
    {continue, CorrelationId}.
```

### Composite Key

When multiple entities involved:

```erlang
correlate(#{data := #{source := Src, dest := Dst}}, _) ->
    {continue, {transfer, Src, Dst}}.
```

## Testing Process Managers

Test the state machine in isolation:

```erlang
-module(order_pm_tests).
-include_lib("eunit/include/eunit.hrl").

full_workflow_test() ->
    %% Initial state
    State0 = #{},

    %% Order placed
    {start, OrderId} = order_pm:correlate(order_placed_event(), #{}),
    State1 = order_pm:apply(State0, order_placed_event()),
    {ok, State2, [PaymentCmd]} = order_pm:handle(State1, order_placed_event(), #{}),

    ?assertEqual(awaiting_payment, maps:get(status, State2)),
    ?assertEqual(process_payment, maps:get(command_type, PaymentCmd)),

    %% Payment received
    State3 = order_pm:apply(State2, payment_received_event()),
    {ok, State4, [ShipCmd]} = order_pm:handle(State3, payment_received_event(), #{}),

    ?assertEqual(awaiting_shipment, maps:get(status, State4)),
    ?assertEqual(ship_item, maps:get(command_type, ShipCmd)),

    %% Item shipped
    State5 = order_pm:apply(State4, item_shipped_event()),
    {ok, State6} = order_pm:handle(State5, item_shipped_event(), #{}),

    ?assertEqual(completed, maps:get(status, State6)).
```

## Telemetry Events

Process managers emit telemetry:

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[evoq, process_manager, start]` | system_time | name, process_id |
| `[evoq, process_manager, stop]` | duration | name, process_id, final_state |
| `[evoq, process_manager, command]` | system_time | name, command_type |
| `[evoq, process_manager, compensate]` | system_time | name, failed_command |

## Best Practices

### 1. Keep Processes Short-Lived

Long-running processes accumulate state and risk:
- Design for completion in minutes/hours, not days
- Split long workflows into smaller processes
- Use timeouts to handle stuck processes

### 2. Make Steps Idempotent

Commands may be dispatched multiple times:

```erlang
handle(State, Event, _Meta) ->
    case already_dispatched(Event, State) of
        true -> {ok, State};
        false ->
            Cmd = create_command(Event),
            {ok, mark_dispatched(Event, State), [Cmd]}
    end.
```

### 3. Handle All Failure Modes

```erlang
interested_in() ->
    [
        %% Happy path
        <<"OrderPlaced">>, <<"PaymentReceived">>, <<"ItemShipped">>,
        %% Failure cases
        <<"PaymentFailed">>, <<"InventoryUnavailable">>, <<"ShippingFailed">>
    ].
```

### 4. Log State Transitions

```erlang
handle(State, Event, _Meta) ->
    OldStatus = maps:get(status, State),
    {ok, NewState, Cmds} = do_handle(State, Event),
    NewStatus = maps:get(status, NewState),

    logger:info("Process ~p: ~p -> ~p on ~p",
        [maps:get(process_id, State), OldStatus, NewStatus, maps:get(event_type, Event)]),

    {ok, NewState, Cmds}.
```

## Next Steps

- [Projections](projections.md) - Build read models
- [Event Handlers](event_handlers.md) - Side effects
- [Architecture](architecture.md) - System overview
