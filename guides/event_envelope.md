# Event Envelope Structure

## Overview

All events in evoq are wrapped in an `evoq_event` envelope that provides metadata, versioning, and cross-stream query capabilities. Understanding this structure is essential for correctly implementing event-sourced systems with evoq.

## The evoq_event Record

Every event stored and transmitted through evoq uses this structure:

```erlang
-record(evoq_event, {
    %% Unique identifier for this event (UUID)
    event_id :: binary(),

    %% Event type (PascalCase with version suffix)
    %% Examples: <<"OrderPlaced.v1">>, <<"UserRegistered.v2">>
    event_type :: binary(),

    %% Stream this event belongs to
    %% Format: <<"{aggregate_type}-{aggregate_id}">>
    %% Examples: <<"order-ord-123">>, <<"user-usr-456">>
    stream_id :: binary(),

    %% Version/position within the stream (0-based, auto-incremented)
    version :: non_neg_integer(),

    %% ┌─────────────────────────────────────────────────────────┐
    %% │ YOUR BUSINESS EVENT PAYLOAD GOES HERE                   │
    %% │ This is what your aggregate returns from execute/2      │
    %% │ This is what your projection receives                   │
    %% └─────────────────────────────────────────────────────────┘
    data :: map() | binary(),

    %% Event metadata (correlation, causation, user context)
    %% Standard fields:
    %%   - correlation_id: Request ID linking related operations
    %%   - causation_id: Command ID or event ID that caused this
    %%   - user_id: Who triggered this
    %%   - timestamp: When it happened
    metadata :: map(),

    %% Tags for cross-stream queries (optional)
    %% Examples: [<<"realm:production">>, <<"tenant:acme">>]
    tags :: [binary()] | undefined,

    %% Timestamp when event was created (milliseconds since epoch)
    timestamp :: integer(),

    %% Microsecond epoch timestamp for precise ordering
    epoch_us :: integer(),

    %% Content type of data field (default: <<"application/json">>)
    data_content_type = <<"application/json">> :: binary(),

    %% Content type of metadata field (default: <<"application/json">>)
    metadata_content_type = <<"application/json">> :: binary()
}).
```

## Event Lifecycle

### 1. Aggregate Returns Business Event

Your aggregate's `execute/2` callback returns a simplified event map:

```erlang
%% In your aggregate module
execute(#{command_type := place_order, amount := Amount}, State) ->
    %% Return simplified event map
    Event = #{
        event_type => <<"OrderPlaced">>,
        data => #{
            order_id => generate_id(),
            amount => Amount,
            placed_at => erlang:system_time(millisecond)
        }
    },
    {ok, [Event]}.
```

**Key Point:** Your aggregate returns ONLY `event_type` and `data`. Evoq handles the rest.

### 2. Evoq Wraps in Envelope

Evoq automatically wraps your business event in the full envelope:

```erlang
%% Evoq creates the full envelope
EvqEvent = #evoq_event{
    event_id = generate_uuid(),
    event_type = <<"OrderPlaced">>,           %% From your event
    stream_id = <<"order-ord-123">>,          %% Derived from aggregate_id
    version = 0,                               %% Auto-incremented
    data = #{                                  %% Your event payload
        order_id => <<"ord-123">>,
        amount => 99.99,
        placed_at => 1703001234567
    },
    metadata = #{                              %% Auto-populated
        correlation_id => get_correlation_id(),
        causation_id => get_command_id(),
        timestamp => erlang:system_time(millisecond)
    },
    tags = [],                                 %% Optional
    timestamp = erlang:system_time(millisecond),
    epoch_us = erlang:system_time(microsecond)
}.
```

### 3. Storage in ReckonDB

The event is persisted to ReckonDB with all envelope fields intact.

### 4. Projection Receives Full Envelope

Your projection's `project/4` callback receives the complete envelope:

```erlang
%% In your projection module
project(#{
    event_type := <<"OrderPlaced">>,
    data := Data,                %% Extract business event payload
    metadata := Metadata         %% Extract metadata
}, _EnvelopeMetadata, State, ReadModel) ->
    OrderId = maps:get(order_id, Data),
    Amount = maps:get(amount, Data),
    CorrelationId = maps:get(correlation_id, Metadata),

    %% Update read model
    update_read_model(ReadModel, OrderId, Amount),
    {ok, State}.
```

## Envelope Fields Explained

### event_id

Unique identifier for this specific event instance (UUID).

**Auto-generated** by evoq. You don't provide this.

**Use cases:**
- Event deduplication
- Causation tracking (this event caused another event)
- Idempotency keys

### event_type

Binary string identifying the event type, typically in PascalCase with version suffix.

**You provide** this in your aggregate's event map.

**Examples:**
```erlang
<<"OrderPlaced.v1">>
<<"UserRegistered.v2">>
<<"PaymentProcessed.v1">>
```

**Best practices:**
- Use past tense (what happened, not what to do)
- Include version suffix for schema evolution
- PascalCase for consistency

### stream_id

Identifier for the event stream (aggregate instance).

**Auto-derived** from command's `aggregate_id`.

**Format:** `<<"{aggregate_type}-{aggregate_id}">>`

**Examples:**
```erlang
<<"order-ord-123">>
<<"user-usr-456">>
<<"cart-cart-789">>
```

### version

Zero-based position of this event within its stream.

**Auto-incremented** by ReckonDB.

**Optimistic concurrency:**
```erlang
%% Append expects current version
{ok, 0} = append_events(Store, <<"order-123">>, -1, [Event1]).
{ok, 1} = append_events(Store, <<"order-123">>, 0, [Event2]).

%% Conflict if version doesn't match
{error, {wrong_expected_version, 1, 5}}
```

### data

**YOUR BUSINESS EVENT PAYLOAD.**

This is what your aggregate returns and what your projections consume.

**Can be:**
- Map (most common): `#{order_id => ..., amount => ...}`
- Binary (for serialized data): `<<"{\"order_id\":\"123\",...}">>`

**Key principle:** The `data` field contains ONLY business event information, no envelope metadata.

### metadata

Cross-cutting metadata about the event.

**Standard fields:**

```erlang
#{
    %% Request ID linking related operations
    correlation_id => <<"req-abc-123">>,

    %% What caused this event (command ID or previous event ID)
    causation_id => <<"cmd-xyz-789">>,

    %% Who triggered this
    user_id => <<"usr-456">>,

    %% When it happened (may differ from envelope timestamp)
    timestamp => 1703001234567,

    %% Additional context
    ip_address => <<"192.168.1.1">>,
    user_agent => <<"Mozilla/5.0...">>
}
```

**Use metadata for:**
- Distributed tracing (correlation_id)
- Causality tracking (causation_id)
- Audit trails (user_id, ip_address)
- Business intelligence

**Do NOT use metadata for:**
- Business event data (belongs in `data` field)
- Aggregate state

### tags

Array of binary tags for cross-stream querying.

**Optional** but powerful for multi-tenant or categorized systems.

**Examples:**
```erlang
%% Multi-tenant
tags => [<<"tenant:acme">>, <<"region:us-east">>]

%% Categorization
tags => [<<"plugin:weather">>, <<"realm:production">>]

%% Entity references
tags => [<<"user:usr-123">>, <<"order:ord-456">>]
```

**Query by tag:**
```erlang
%% Find all events for a tenant
Events = reckon_db:query_by_tag(Store, <<"tenant:acme">>).
```

### timestamp & epoch_us

When the event was created.

**Auto-generated** by evoq.

- `timestamp`: Milliseconds since Unix epoch
- `epoch_us`: Microseconds since Unix epoch (for precise ordering)

## Event Naming Conventions

| Component | Format | Example |
|-----------|--------|---------|
| **event_type** | PascalCase.vN | `<<"OrderPlaced.v1">>` |
| **Aggregate module** | snake_case | `order_aggregate.erl` |
| **Event handler** | maybe_{verb}_{subject} | `maybe_place_order.erl` |
| **Stream ID** | `{type}-{id}` | `<<"order-ord-123">>` |

## Metadata Best Practices

### Always Include

```erlang
metadata => #{
    correlation_id => generate_or_get_correlation_id(),
    causation_id => get_causation_id(),
    timestamp => erlang:system_time(millisecond)
}
```

### Context-Specific

```erlang
%% User-triggered actions
metadata => #{
    ...,
    user_id => get_user_id(),
    ip_address => get_client_ip(),
    user_agent => get_user_agent()
}

%% System-triggered actions
metadata => #{
    ...,
    triggered_by => <<"system">>,
    reason => <<"scheduled_task">>
}
```

## Event Versioning

Support schema evolution using version suffixes:

```erlang
%% Version 1 (initial)
#{
    event_type => <<"OrderPlaced.v1">>,
    data => #{
        order_id => <<"ord-123">>,
        amount => 99.99
    }
}

%% Version 2 (added currency)
#{
    event_type => <<"OrderPlaced.v2">>,
    data => #{
        order_id => <<"ord-123">>,
        amount => 99.99,
        currency => <<"USD">>  %% New field
    }
}
```

**Handle in projections:**
```erlang
project(#{event_type := <<"OrderPlaced.v1">>, data := D}, _, State, RM) ->
    %% Upgrade v1 to v2 format
    D2 = D#{currency => <<"USD">>},  %% Default currency
    process_order_placed_v2(D2, State, RM);

project(#{event_type := <<"OrderPlaced.v2">>, data := D}, _, State, RM) ->
    process_order_placed_v2(D, State, RM).
```

## Common Mistakes

### ❌ Including Envelope Fields in data

```erlang
%% WRONG - envelope fields in data
data => #{
    event_id => <<"evt-123">>,           %% NO - envelope field
    event_type => <<"OrderPlaced">>,     %% NO - envelope field
    correlation_id => <<"req-abc">>,     %% NO - belongs in metadata
    order_id => <<"ord-123">>,           %% OK
    amount => 99.99                      %% OK
}
```

**Correct:**
```erlang
%% RIGHT - clean separation
data => #{
    order_id => <<"ord-123">>,
    amount => 99.99
},
metadata => #{
    correlation_id => <<"req-abc">>
}
```

### ❌ Using event_type as Atom

```erlang
%% WRONG - atom
event_type => order_placed

%% RIGHT - binary
event_type => <<"OrderPlaced.v1">>
```

### ❌ Putting User Context in data

```erlang
%% WRONG
data => #{
    order_id => <<"ord-123">>,
    user_id => <<"usr-456">>,        %% NO - belongs in metadata
    amount => 99.99
}

%% RIGHT
data => #{
    order_id => <<"ord-123">>,
    amount => 99.99
},
metadata => #{
    user_id => <<"usr-456">>         %% YES - user context
}
```

## Visual Reference

See `assets/event-envelope-diagram.svg` for a visual representation of the event lifecycle.

## See Also

- [Aggregates Guide](aggregates.md) - How aggregates produce events
- [Projections Guide](projections.md) - How projections consume events
- [Event Sourcing Guide](/reckon-db/guides/event_sourcing.md) - Event sourcing patterns with ReckonDB
