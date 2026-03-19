# State Modules

State modules separate the aggregate's data shape and event folding from its command validation and business rules. The aggregate decides WHAT happens; the state module decides HOW the data changes.

![Aggregate/State Separation](assets/aggregate-state-separation.svg)

## The "Default Read Model"

The aggregate state IS the complete truth about one process instance. It is the "default read model" -- the authoritative representation of everything that has happened to a single aggregate, built by replaying every event in order.

This matters because:

1. **Event payloads** are a subset of aggregate state plus new data from the command
2. **Command payloads** are a subset of aggregate state plus enrichment from outside (read models, user input)
3. **Data from outside the bounded context** enters ONLY through enriched command payloads
4. **Inside the CMD flow** (aggregate state, events, process managers) there are NO external lookups

The practical test: "Can I delete all read models, replay events, and get the same aggregate state?" If yes, the state module is correctly self-contained.

## Why Separate State?

Without separation, the aggregate handles three concerns:

- Command validation and business rules
- Data shape and field access
- Event folding and serialization

Pulling the last two into a dedicated state module gives you:

| Concern | Aggregate | State Module |
|---------|-----------|-------------|
| Command validation | Yes | No |
| Business rules | Yes | No |
| Data shape (record) | No | Yes |
| Field access | No | Yes |
| Event folding | No | Yes |
| Serialization | No | Yes |

The aggregate becomes a pure decision-maker. The state module becomes a pure data transformer.

## The evoq_state Behaviour

The behaviour is defined in `evoq_state` and provides three required callbacks plus one optional.

### Required Callbacks

**new/1** -- Create initial (empty) state for a new aggregate.

```erlang
-callback new(AggregateId :: binary()) -> State :: term().
```

Called when an aggregate is first created. Returns the initial state before any events have been applied.

**apply_event/2** -- Apply a single event to update state.

```erlang
-callback apply_event(State :: term(), Event :: map()) -> State :: term().
```

Must be pure and deterministic. Called for each event produced by execute/2 and during replay. Same input must always produce same output, with no side effects.

**to_map/1** -- Serialize state to a map.

```erlang
-callback to_map(State :: term()) -> map().
```

Used for session-level consistency feedback (dispatch_with_state/2), snapshot serialization, and programmatic state inspection.

### Optional Callbacks

**from_map/1** -- Deserialize state from a map.

```erlang
-callback from_map(Map :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.
```

Used for snapshot loading and state reconstruction from external sources. If not implemented, snapshot loading is not available.

## Declaring the State Module

Every aggregate MUST declare which state module it uses via the state_module/0 callback:

```erlang
-module(counter_aggregate).
-behaviour(evoq_aggregate).

state_module() -> counter_state.
```

The aggregate then delegates state operations to the state module:

```erlang
init(AggregateId) ->
    {ok, counter_state:new(AggregateId)}.

apply(State, Event) ->
    counter_state:apply_event(State, Event).
```

## Complete Example

A counter aggregate that supports increment and decrement operations.

### The State Record

```erlang
%% include/counter_state.hrl

-record(counter_state, {
    id        :: binary(),
    value = 0 :: integer(),
    status = 0 :: non_neg_integer()  %% bit flags
}).
```

### The State Module

```erlang
-module(counter_state).
-behaviour(evoq_state).

-include("counter_state.hrl").

-export([new/1, apply_event/2, to_map/1, from_map/1]).

%% --- evoq_state callbacks ---

new(AggregateId) ->
    #counter_state{id = AggregateId}.

apply_event(State, #{event_type := <<"CounterInitiated">>, data := Data}) ->
    State#counter_state{
        value = maps:get(initial_value, Data, 0),
        status = evoq_bit_flags:set(0, 1)  %% flag 1 = initiated
    };
apply_event(#counter_state{value = V} = State, #{event_type := <<"CounterIncremented">>, data := #{amount := Amount}}) ->
    State#counter_state{value = V + Amount};
apply_event(#counter_state{value = V} = State, #{event_type := <<"CounterDecremented">>, data := #{amount := Amount}}) ->
    State#counter_state{value = V - Amount}.

to_map(#counter_state{id = Id, value = Value, status = Status}) ->
    #{
        id => Id,
        value => Value,
        status => Status
    }.

from_map(#{id := Id, value := Value, status := Status}) ->
    {ok, #counter_state{id = Id, value = Value, status = Status}};
from_map(_) ->
    {error, invalid_state_map}.
```

### The Aggregate

```erlang
-module(counter_aggregate).
-behaviour(evoq_aggregate).

-include("counter_state.hrl").

-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> counter_state.

init(AggregateId) ->
    {ok, counter_state:new(AggregateId)}.

%% --- Command validation and business rules ---

execute(#counter_state{status = 0}, #{command_type := initiate_counter, initial_value := Value}) ->
    {ok, [#{event_type => <<"CounterInitiated">>, data => #{initial_value => Value}}]};
execute(#counter_state{status = 0}, _Command) ->
    {error, counter_not_initiated};

execute(#counter_state{}, #{command_type := increment, amount := Amount}) when Amount > 0 ->
    {ok, [#{event_type => <<"CounterIncremented">>, data => #{amount => Amount}}]};
execute(#counter_state{}, #{command_type := increment, amount := Amount}) when Amount =< 0 ->
    {error, {invalid_amount, Amount}};

execute(#counter_state{value = V}, #{command_type := decrement, amount := Amount})
  when Amount > 0, V >= Amount ->
    {ok, [#{event_type => <<"CounterDecremented">>, data => #{amount => Amount}}]};
execute(#counter_state{value = V}, #{command_type := decrement, amount := Amount})
  when Amount > 0, V < Amount ->
    {error, {would_go_negative, V, Amount}};

execute(_State, _Command) ->
    {error, unknown_command}.

%% --- Delegate event folding to state module ---

apply(State, Event) ->
    counter_state:apply_event(State, Event).
```

Notice how the aggregate focuses entirely on command validation (business rules, guards, preconditions) while the state module handles data transformation. The aggregate pattern-matches on state to enforce rules but never directly modifies the record.

## Conventions

### Naming

State modules follow the pattern: the noun that the aggregate manages, suffixed with _state.

| Aggregate | State Module | Header |
|-----------|-------------|--------|
| venture_aggregate | venture_state | venture_state.hrl |
| order_aggregate | order_state | order_state.hrl |
| counter_aggregate | counter_state | counter_state.hrl |

### Record and Header

The state record is defined in a header file named after the state module. Both the aggregate and the state module include it:

```erlang
%% In counter_state.erl
-include("counter_state.hrl").

%% In counter_aggregate.erl
-include("counter_state.hrl").
```

This allows the aggregate to pattern-match on state fields for command validation without duplicating the record definition.

### Purity

apply_event/2 MUST be pure and deterministic:

- No side effects (no I/O, no process messaging, no ETS writes)
- No calls to erlang:system_time or other non-deterministic functions
- Same event applied to same state always produces same result
- This guarantees correct replay from the event store

### Serialization

to_map/1 serves three purposes:

1. **Session-level consistency** -- dispatch_with_state/2 returns the aggregate state as a map to the caller, enabling immediate feedback without waiting for projections
2. **Snapshot serialization** -- Snapshots store the aggregate state for faster loading
3. **Programmatic inspection** -- Debugging, monitoring, and tooling can inspect state without knowing the record structure

### Status as Bit Flags

Status fields in state records MUST be integers treated as bit flags. Use evoq_bit_flags for all status manipulation:

```erlang
-define(INITIATED,  1).  %% 2^0
-define(ACTIVE,     2).  %% 2^1
-define(SUSPENDED,  4).  %% 2^2
-define(ARCHIVED,   8).  %% 2^3

apply_event(State, #{event_type := <<"CounterInitiated">>} = _Event) ->
    State#counter_state{
        status = evoq_bit_flags:set(0, ?INITIATED)
    }.
```

## Testing State Modules

State modules are easy to test in isolation since they are pure functions:

```erlang
-module(counter_state_tests).
-include_lib("eunit/include/eunit.hrl").
-include("counter_state.hrl").

new_test() ->
    State = counter_state:new(<<"test-1">>),
    ?assertEqual(<<"test-1">>, State#counter_state.id),
    ?assertEqual(0, State#counter_state.value).

apply_increment_test() ->
    State0 = counter_state:new(<<"test-1">>),
    Event = #{event_type => <<"CounterIncremented">>, data => #{amount => 5}},
    State1 = counter_state:apply_event(State0, Event),
    ?assertEqual(5, State1#counter_state.value).

roundtrip_serialization_test() ->
    State0 = counter_state:new(<<"test-1">>),
    Map = counter_state:to_map(State0),
    {ok, State1} = counter_state:from_map(Map),
    ?assertEqual(State0, State1).
```

Because apply_event/2 is pure, you can test every event type without standing up any infrastructure. Compose events to test complex state transitions:

```erlang
full_lifecycle_test() ->
    State0 = counter_state:new(<<"test-1">>),
    Events = [
        #{event_type => <<"CounterInitiated">>, data => #{initial_value => 10}},
        #{event_type => <<"CounterIncremented">>, data => #{amount => 5}},
        #{event_type => <<"CounterDecremented">>, data => #{amount => 3}}
    ],
    Final = lists:foldl(fun counter_state:apply_event/2, State0, Events),
    ?assertEqual(12, Final#counter_state.value).
```

## Next Steps

- [Aggregates](aggregates.md) -- Command validation and business rules
- [Projections](projections.md) -- Build read models from events
- [Integration Actors](integration_actors.md) -- Move facts across boundaries
- [Bit Flags](bit_flags.md) -- Status field conventions
