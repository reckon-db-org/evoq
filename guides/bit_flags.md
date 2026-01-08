# Working with Bit Flags in Evoq

The `evoq_bit_flags` module provides a comprehensive set of functions for working with bitwise flags in Erlang. This module is particularly useful for event-sourced systems where aggregate state can be represented efficiently as a set of flags (finite state machine).

## Table of Contents

- [Overview](#overview)
- [Why Use Bit Flags?](#why-use-bit-flags)
- [Basic Concepts](#basic-concepts)
- [Core Functions](#core-functions)
- [Query Operations](#query-operations)
- [Conversion Operations](#conversion-operations)
- [Aggregate State Management](#aggregate-state-management)
- [Best Practices](#best-practices)
- [Function Reference](#function-reference)

## Overview

The `evoq_bit_flags` module offers:

- **Efficient state representation** using bitwise operations
- **Multiple flag manipulation** functions
- **State querying** and validation capabilities
- **Human-readable conversions** with flag maps
- **Event sourcing support** for aggregate state management
- **Performance-optimized operations** using Erlang's bitwise operators

## Why Use Bit Flags?

1. **Memory Efficiency**: Store multiple boolean states in a single integer
2. **Performance**: Bitwise operations are extremely fast (CPU-native)
3. **Atomic Operations**: Update multiple flags in a single operation
4. **Event Sourcing**: Efficiently represent aggregate state in event streams
5. **Database Queries**: Use bitwise operators in SQL/NoSQL queries
6. **Network Efficiency**: Single integer travels over the wire vs multiple booleans

## Basic Concepts

### What are Bit Flags?

Bit flags represent multiple boolean states in a single integer using binary representation. Each bit position corresponds to a specific flag or state.

```erlang
%% Binary representation: 2#01100100 = 100 in decimal
%% Bit positions:         76543210
%%                        01100100
%% This represents flags at positions 2, 5, and 6 being set
```

### Powers of Two

Flags MUST be defined as powers of 2 to ensure each flag occupies a unique bit position:

```erlang
-define(NONE,             0).   %% 2#00000000
-define(CREATED,          1).   %% 2#00000001  (2^0)
-define(VALIDATED,        2).   %% 2#00000010  (2^1)
-define(PROCESSING,       4).   %% 2#00000100  (2^2)
-define(COMPLETED,        8).   %% 2#00001000  (2^3)
-define(CANCELLED,       16).   %% 2#00010000  (2^4)
-define(ARCHIVED,        32).   %% 2#00100000  (2^5)
-define(READY_TO_PUBLISH,64).   %% 2#01000000  (2^6)
-define(PUBLISHED,      128).   %% 2#10000000  (2^7)
```

### Flag Map for Human-Readable Output

```erlang
flag_map() ->
    #{
        0   => <<"None">>,
        1   => <<"Created">>,
        2   => <<"Validated">>,
        4   => <<"Processing">>,
        8   => <<"Completed">>,
        16  => <<"Cancelled">>,
        32  => <<"Archived">>,
        64  => <<"Ready to Publish">>,
        128 => <<"Published">>
    }.
```

## Core Functions

### Setting Flags

#### Single Flag

```erlang
%% Set a single flag
State0 = 0,                                    %% 2#00000000
State1 = evoq_bit_flags:set(State0, 4),        %% 2#00000100 (Processing)
%% State1 = 4

%% Set another flag
State2 = evoq_bit_flags:set(State1, 32),       %% 2#00100100 (Processing + Archived)
%% State2 = 36
```

#### Multiple Flags

```erlang
%% Set multiple flags at once
State0 = 0,
State1 = evoq_bit_flags:set_all(State0, [1, 4, 32]),
%% State1 = 37 (Created + Processing + Archived)
```

### Unsetting Flags

#### Single Flag

```erlang
%% Unset a single flag
State0 = 100,                                  %% 2#01100100 (Processing + Archived + Ready)
State1 = evoq_bit_flags:unset(State0, 64),     %% Remove "Ready to Publish"
%% State1 = 36 (2#00100100)
```

#### Multiple Flags

```erlang
%% Unset multiple flags
State0 = 228,                                  %% 2#11100100
State1 = evoq_bit_flags:unset_all(State0, [64, 128]),
%% State1 = 36
```

## Query Operations

### Check Single Flag

```erlang
State = 100,                                   %% 2#01100100

true  = evoq_bit_flags:has(State, 4),          %% Processing is set
false = evoq_bit_flags:has(State, 8),          %% Completed is NOT set
true  = evoq_bit_flags:has_not(State, 8),      %% Completed is NOT set
```

### Check Multiple Flags

```erlang
State = 100,                                   %% 2#01100100

%% Check if ALL flags are set
true  = evoq_bit_flags:has_all(State, [4, 32, 64]),
false = evoq_bit_flags:has_all(State, [4, 8]),

%% Check if ANY flag is set
true  = evoq_bit_flags:has_any(State, [8, 64]),    %% 64 is set
false = evoq_bit_flags:has_any(State, [1, 2, 8]),  %% None are set
```

## Conversion Operations

### Decomposition

Extract all power-of-two components from a number:

```erlang
[4, 32, 64] = evoq_bit_flags:decompose(100),
[1, 2, 4, 8] = evoq_bit_flags:decompose(15).
```

### Human-Readable Conversion

```erlang
FlagMap = #{
    4  => <<"Processing">>,
    32 => <<"Archived">>,
    64 => <<"Ready to Publish">>
},

%% Convert to list of descriptions
[<<"Processing">>, <<"Archived">>, <<"Ready to Publish">>] =
    evoq_bit_flags:to_list(100, FlagMap),

%% Convert to comma-separated string
<<"Processing, Archived, Ready to Publish">> =
    evoq_bit_flags:to_string(100, FlagMap),

%% With custom separator
<<"Processing | Archived | Ready to Publish">> =
    evoq_bit_flags:to_string(100, FlagMap, <<" | ">>).
```

### State Analysis

```erlang
FlagMap = #{
    4  => <<"Processing">>,
    32 => <<"Archived">>,
    64 => <<"Ready to Publish">>
},

State = 100,

%% Get highest priority flag
<<"Ready to Publish">> = evoq_bit_flags:highest(State, FlagMap),

%% Get lowest priority flag
<<"Processing">> = evoq_bit_flags:lowest(State, FlagMap).
```

## Aggregate State Management

### Defining Status Flags for an Aggregate

Create a header file with your aggregate's status flags:

```erlang
%% include/order_status.hrl

-define(ORDER_NONE,             0).
-define(ORDER_CREATED,          1).
-define(ORDER_PAYMENT_PENDING,  2).
-define(ORDER_PAYMENT_CONFIRMED,4).
-define(ORDER_PROCESSING,       8).
-define(ORDER_SHIPPED,         16).
-define(ORDER_DELIVERED,       32).
-define(ORDER_CANCELLED,       64).
-define(ORDER_REFUNDED,       128).

-define(ORDER_STATUS_MAP, #{
    ?ORDER_NONE             => <<"None">>,
    ?ORDER_CREATED          => <<"Created">>,
    ?ORDER_PAYMENT_PENDING  => <<"Payment Pending">>,
    ?ORDER_PAYMENT_CONFIRMED=> <<"Payment Confirmed">>,
    ?ORDER_PROCESSING       => <<"Processing">>,
    ?ORDER_SHIPPED          => <<"Shipped">>,
    ?ORDER_DELIVERED        => <<"Delivered">>,
    ?ORDER_CANCELLED        => <<"Cancelled">>,
    ?ORDER_REFUNDED         => <<"Refunded">>
}).
```

### Aggregate with Bit Flag Status

```erlang
-module(order_aggregate).
-behaviour(evoq_aggregate).

-include("order_status.hrl").

-record(order, {
    id :: binary(),
    status :: non_neg_integer(),  %% Bit flags!
    customer_id :: binary(),
    items :: list(),
    total :: number()
}).

%% Initialize with CREATED flag
init(#{id := Id, customer_id := CustomerId}) ->
    #order{
        id = Id,
        status = ?ORDER_CREATED,
        customer_id = CustomerId,
        items = [],
        total = 0
    }.

%% Apply events - update status flags
apply_event(#order{status = Status} = Order, {payment_requested, _}) ->
    NewStatus = evoq_bit_flags:set(Status, ?ORDER_PAYMENT_PENDING),
    Order#order{status = NewStatus};

apply_event(#order{status = Status} = Order, {payment_confirmed, _}) ->
    NewStatus = Status
        |> evoq_bit_flags:unset(?ORDER_PAYMENT_PENDING)
        |> evoq_bit_flags:set(?ORDER_PAYMENT_CONFIRMED),
    Order#order{status = NewStatus};

apply_event(#order{status = Status} = Order, {order_shipped, _}) ->
    NewStatus = Status
        |> evoq_bit_flags:unset(?ORDER_PROCESSING)
        |> evoq_bit_flags:set(?ORDER_SHIPPED),
    Order#order{status = NewStatus};

apply_event(#order{status = Status} = Order, {order_cancelled, _}) ->
    NewStatus = evoq_bit_flags:set(Status, ?ORDER_CANCELLED),
    Order#order{status = NewStatus}.

%% Business rule checks using flags
can_cancel(#order{status = Status}) ->
    %% Can cancel if not shipped, delivered, or already cancelled
    not evoq_bit_flags:has_any(Status, [?ORDER_SHIPPED, ?ORDER_DELIVERED, ?ORDER_CANCELLED]).

can_refund(#order{status = Status}) ->
    %% Can refund if payment confirmed and not already refunded
    evoq_bit_flags:has(Status, ?ORDER_PAYMENT_CONFIRMED)
        andalso not evoq_bit_flags:has(Status, ?ORDER_REFUNDED).

is_active(#order{status = Status}) ->
    %% Active if not in terminal state
    not evoq_bit_flags:has_any(Status, [?ORDER_DELIVERED, ?ORDER_CANCELLED, ?ORDER_REFUNDED]).

get_status_string(#order{status = Status}) ->
    evoq_bit_flags:to_string(Status, ?ORDER_STATUS_MAP).

get_current_stage(#order{status = Status}) ->
    evoq_bit_flags:highest(Status, ?ORDER_STATUS_MAP).
```

### Command Handler with Status Validation

```erlang
-module(maybe_cancel_order).

-include("order_status.hrl").

handle(Order, {cancel_order, Reason}) ->
    case order_aggregate:can_cancel(Order) of
        true ->
            {ok, [{order_cancelled, #{reason => Reason, cancelled_at => erlang:timestamp()}}]};
        false ->
            Status = order_aggregate:get_status_string(Order),
            {error, {cannot_cancel, <<"Order in state: ", Status/binary>>}}
    end.
```

## Best Practices

### 1. Always Use Powers of Two

```erlang
%% CORRECT - unique bit positions
-define(FLAG_A, 1).   %% 2^0
-define(FLAG_B, 2).   %% 2^1
-define(FLAG_C, 4).   %% 2^2
-define(FLAG_D, 8).   %% 2^3

%% WRONG - overlapping bits!
-define(BAD_A, 1).
-define(BAD_B, 3).    %% 3 = 1 + 2, conflicts with FLAG_A!
-define(BAD_C, 5).    %% 5 = 1 + 4, conflicts with FLAG_A!
```

### 2. Define Constants in Header Files

Keep all flag definitions in `.hrl` files for consistency:

```erlang
%% include/task_status.hrl
-ifndef(TASK_STATUS_HRL).
-define(TASK_STATUS_HRL, true).

-define(TASK_CREATED,    1).
-define(TASK_ASSIGNED,   2).
-define(TASK_IN_PROGRESS,4).
-define(TASK_COMPLETED,  8).
-define(TASK_ARCHIVED,  16).

-define(TASK_STATUS_MAP, #{
    ?TASK_CREATED     => <<"Created">>,
    ?TASK_ASSIGNED    => <<"Assigned">>,
    ?TASK_IN_PROGRESS => <<"In Progress">>,
    ?TASK_COMPLETED   => <<"Completed">>,
    ?TASK_ARCHIVED    => <<"Archived">>
}).

-endif.
```

### 3. Validate State Transitions

Always validate that state transitions are valid:

```erlang
complete_task(Status) ->
    case evoq_bit_flags:has(Status, ?TASK_ARCHIVED) of
        true ->
            {error, cannot_complete_archived_task};
        false ->
            case evoq_bit_flags:has(Status, ?TASK_IN_PROGRESS) of
                true ->
                    {ok, evoq_bit_flags:set(Status, ?TASK_COMPLETED)};
                false ->
                    {error, task_must_be_in_progress}
            end
    end.
```

### 4. Document Valid Flag Combinations

```erlang
%% @doc Order status flags.
%%
%% Valid state transitions:
%% - CREATED -> PAYMENT_PENDING
%% - PAYMENT_PENDING -> PAYMENT_CONFIRMED | CANCELLED
%% - PAYMENT_CONFIRMED -> PROCESSING
%% - PROCESSING -> SHIPPED | CANCELLED
%% - SHIPPED -> DELIVERED
%% - Any (except DELIVERED) -> CANCELLED
%% - PAYMENT_CONFIRMED + (CANCELLED | DELIVERED) -> REFUNDED
%%
%% Terminal states: DELIVERED, CANCELLED + REFUNDED
```

### 5. Use Flags for Read Model Queries

```erlang
%% Query all orders that are shipped but not delivered
find_in_transit_orders(Repo) ->
    ShippedFlag = ?ORDER_SHIPPED,
    DeliveredFlag = ?ORDER_DELIVERED,
    %% SQL: WHERE (status & 16) = 16 AND (status & 32) = 0
    Repo:select_where([
        {'band', status, ShippedFlag, ShippedFlag},
        {'band', status, DeliveredFlag, 0}
    ]).
```

## Function Reference

### Core Operations

| Function | Description | Example |
|----------|-------------|---------|
| `set(Target, Flag)` | Set a single flag | `set(0, 4)` -> `4` |
| `unset(Target, Flag)` | Unset a single flag | `unset(7, 4)` -> `3` |
| `set_all(Target, Flags)` | Set multiple flags | `set_all(0, [1, 4])` -> `5` |
| `unset_all(Target, Flags)` | Unset multiple flags | `unset_all(7, [1, 2])` -> `4` |

### Query Operations

| Function | Description | Example |
|----------|-------------|---------|
| `has(Target, Flag)` | Check if flag is set | `has(5, 4)` -> `true` |
| `has_not(Target, Flag)` | Check if flag is not set | `has_not(5, 2)` -> `true` |
| `has_all(Target, Flags)` | Check if all flags are set | `has_all(7, [1, 2])` -> `true` |
| `has_any(Target, Flags)` | Check if any flag is set | `has_any(5, [2, 4])` -> `true` |

### Conversion Operations

| Function | Description | Example |
|----------|-------------|---------|
| `to_list(Target, FlagMap)` | Convert to list of descriptions | Returns list of binaries |
| `to_string(Target, FlagMap)` | Convert to comma-separated string | Returns binary |
| `to_string(Target, FlagMap, Sep)` | Convert with custom separator | Returns binary |
| `decompose(Target)` | Get power-of-2 components | `decompose(7)` -> `[1, 2, 4]` |

### Analysis Operations

| Function | Description | Example |
|----------|-------------|---------|
| `highest(Target, FlagMap)` | Get highest set flag description | Returns binary or undefined |
| `lowest(Target, FlagMap)` | Get lowest set flag description | Returns binary or undefined |

### Binary Representation Quick Reference

| Decimal | Binary | Flags Set |
|---------|--------|-----------|
| 0 | 2#00000000 | None |
| 1 | 2#00000001 | Flag 0 (2^0) |
| 2 | 2#00000010 | Flag 1 (2^1) |
| 3 | 2#00000011 | Flags 0, 1 |
| 4 | 2#00000100 | Flag 2 (2^2) |
| 5 | 2#00000101 | Flags 0, 2 |
| 7 | 2#00000111 | Flags 0, 1, 2 |
| 15 | 2#00001111 | Flags 0, 1, 2, 3 |
| 255 | 2#11111111 | All 8 flags |

---

*This guide covers the complete functionality of the `evoq_bit_flags` module. Bit flags are particularly powerful for event sourcing, state machines, and any scenario where you need to efficiently represent multiple boolean states in aggregates.*
