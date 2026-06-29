# evoq guides

Developer reference for [evoq](../README.md), the standalone Erlang CQRS /
event-sourcing framework (aggregates, projections, process managers, decisions).
evoq has no Reckon dependencies; it pairs with any event store through an
adapter. Each page is self-contained; read by topic or follow one of the
suggested orders below.

## Core write side

| Guide | What it covers |
|---|---|
| [Architecture](architecture.md) | How the CQRS / event-sourcing components fit together: command router, aggregates, handlers, projections, the middleware pipeline. |
| [Aggregates](aggregates.md) | The core domain building block: `init` / `execute` / `apply`, invariants, snapshotting, lifecycle and TTL. |
| [State Modules](state_modules.md) | Separating an aggregate's data shape and event folding from its command validation and business rules. |
| [Event Envelope](event_envelope.md) | The `evoq_event` wrapper: metadata, versioning, lineage keys, and cross-stream query fields. |

## Decisions (DCB and CCC)

| Guide | What it covers |
|---|---|
| [Decisions](decisions.md) | The `evoq_decision` write-side construct: locking on the absence of events matching a tag-filter context (Dynamic Consistency Boundary) rather than a single stream's version. Covers tag / `event_type` / compound (`and_` / `or_`) filters, CCC payload conditions (`payload_match` / `payload_hash_match`), and the opt-in stateful decision actor (`boundary_key/1`) for keyed, hot boundaries. |

## Read side and reactions

| Guide | What it covers |
|---|---|
| [Event Handlers](event_handlers.md) | Reacting to events with side effects; per-event-type subscriptions, retry strategies, and dead-letter support. |
| [Process Managers](process_managers.md) | Sagas that coordinate long-running workflows across aggregates, with command dispatch and compensation. |
| [Projections](projections.md) | Building optimized read models from events, with checkpointing. |

## Integration boundary

| Guide | What it covers |
|---|---|
| [Domain and Integration Artifacts](artifacts.md) | The four artifact types (command, event, fact, hope) and when domain artifacts cross into integration artifacts. |
| [Integration Actors](integration_actors.md) | The actor behaviours that move integration artifacts across bounded-context boundaries, plus the RPC feedback type. |
| [Adapters](adapters.md) | Configuring and implementing event-store adapters; how evoq stays store-agnostic. |

## Utilities and operations

| Guide | What it covers |
|---|---|
| [Bit Flags](bit_flags.md) | `evoq_bit_flags`: representing aggregate state compactly as a finite-state-machine bitfield. |
| [Store Inspector](store_inspector.md) | Store-level introspection for debugging and monitoring via the configured adapter. |

## Suggested reading orders

**I am modelling a domain on evoq:**

1. [Architecture](architecture.md)
2. [Aggregates](aggregates.md), then [State Modules](state_modules.md)
3. [Event Envelope](event_envelope.md)
4. [Projections](projections.md), then [Event Handlers](event_handlers.md) and [Process Managers](process_managers.md)

**I need strong consistency across streams (DCB / CCC):**

1. [Decisions](decisions.md)
2. The [reckon-db DCB guide](https://codeberg.org/reckon-db-org/reckon-db/src/branch/main/guides/dcb.md) and [CCC guide](https://codeberg.org/reckon-db-org/reckon-db/src/branch/main/guides/ccc.md) for the primitive-level backend reference

**I am integrating across bounded contexts:**

1. [Domain and Integration Artifacts](artifacts.md)
2. [Integration Actors](integration_actors.md)
3. [Adapters](adapters.md)

For the ecosystem map (gater, reckon-db, reckon-evoq, gateway, Go client, and
more), see the [Reckon stack](../README.md#reckon-stack) section in the
top-level README.
