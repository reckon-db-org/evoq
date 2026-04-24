# Changelog

All notable changes to evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.14.3] - 2026-04-23

### Fixed

- `evoq_aggregate:rebuild_from_events/3` now reports version `-1` for an
  empty stream, matching `load_or_init/3`. It previously returned `0`,
  which caused the dispatcher's `wrong_expected_version` retry loop to
  spin forever against a Ra stream at version `-1` — each retry handed
  the backend `expected_version=0` for a stream that had never been
  written. Regression test in `test/unit/evoq_aggregate_rebuild_tests.erl`.

## [1.14.2] - 2026-04-19

### Changed

- Updated cross-references in `include/evoq_types.hrl` from
  `esdb_gater_types.hrl` to `reckon_gater_types.hrl` following the
  rename in reckon-gater 2.0.0. No API changes — comment/docs only.

## [1.13.1] - 2026-03-19

### Added

- Unit tests for `evoq_store_inspector`
- Guide: `guides/store_inspector.md` with usage examples
- Architecture diagram: `assets/store_inspector.svg`

## [1.13.0] - 2026-03-19

### Added

- **`evoq_store_inspector`** (NEW): Store-level introspection via adapter.
  - `store_stats/1`, `list_all_snapshots/1`, `list_subscriptions/1`
  - `subscription_lag/2`, `event_type_summary/1`, `stream_info/2`
  - Delegates to the configured event store adapter (graceful fallback if not supported)

## [1.12.0] - 2026-03-14

### Added

- **`evoq_state` behaviour** (NEW): Formalizes the aggregate state as a first-class
  module — the "default read model". Every aggregate MUST have a corresponding state
  module declared via `state_module/0`. Required callbacks: `new/1`, `apply_event/2`,
  `to_map/1`. Optional: `from_map/1`. This separation keeps the aggregate focused on
  command validation and business rules, while the state module owns the data shape,
  field access, event folding, and serialization.

- **`evoq_aggregate:state_module/0` callback** (REQUIRED): Every aggregate must now
  declare which module implements `evoq_state` for its state. This makes codegen fully
  mechanical — every aggregate gets a state module, no exceptions.

## [1.11.0] - 2026-03-14

### Added

- **`evoq_emitter` behaviour** (NEW): Formalizes emitters that subscribe to domain
  events and publish integration facts to external transports (pg or mesh). Required
  callbacks: `source_event/0`, `fact_module/0`, `transport/0`, `emit/3`.

- **`evoq_listener` behaviour** (NEW): Formalizes listeners that receive integration
  facts from external transports and dispatch commands to the local aggregate. Required
  callbacks: `source_fact/0`, `transport/0`, `handle_fact/3`.

- **`evoq_requester` behaviour** (NEW): Formalizes requesters that send hopes over
  mesh and wait for feedback (cross-daemon RPC). Required callbacks: `hope_module/0`,
  `send/2`.

- **`evoq_responder` behaviour** (NEW): Formalizes responders that receive hopes,
  dispatch commands, and return feedback with the post-event aggregate state. Required
  callbacks: `hope_type/0`, `handle_hope/3`. Optional: `feedback_module/0`.

- **`evoq_feedback` behaviour** (NEW): Typed feedback for hope/response cycles.
  Serializes command execution results (`{ok, State}` or `{error, Reason}`) for
  transport. Required callbacks: `feedback_type/0`, `from_result/1`, `to_result/1`.
  Optional: `serialize/1`, `deserialize/1`. Default JSON serialization provided.

- **`evoq_aggregate:execute_command_with_state/2`**: Execute a command and return
  the post-event aggregate state along with version and events. Enables session-level
  consistency where callers receive immediate truth about the resulting state.

- **`evoq_dispatcher:dispatch_with_state/2`**: Dispatch a command through the
  middleware pipeline and return `{ok, Version, Events, AggregateState}` on success.
  Full middleware pipeline, idempotency, and consistency support.

## [1.10.0] - 2026-03-14

### Added

- **`evoq_command` behaviour expanded**: Commands are now formal domain artifacts.
  Added required callbacks `command_type/0`, `new/1`, `to_map/1` and optional
  `from_map/1`. Existing `validate/1` remains optional. Modules without the
  behaviour continue to work unchanged -- the callbacks are opt-in.

- **`evoq_event` behaviour** (NEW): Events are formal domain artifacts with
  required callbacks `event_type/0`, `new/1`, `to_map/1` and optional `from_map/1`.
  Event construction via `new/1` returns the event directly (no `{ok, _}` wrapper)
  since events are produced from validated handler output.

- **`evoq_fact` behaviour** (NEW): Integration artifacts for cross-boundary
  communication. Facts translate domain events into serializable payloads with
  binary keys for external consumption via pg or mesh. Required callbacks:
  `fact_type/0` (returns binary topic), `from_event/3` (translates event to
  payload or returns `skip`). Optional: `serialize/1`, `deserialize/1`, `schema/0`.
  Default JSON serialization via OTP 27 `json` module provided as
  `evoq_fact:default_serialize/1` and `default_deserialize/1`.

- **`evoq_hope` behaviour** (NEW): Integration artifacts for outbound RPC
  requests between agents. Required: `hope_type/0`, `new/1`, `to_payload/1`,
  `from_payload/1`. Optional: `validate/1`, `serialize/1`, `deserialize/1`,
  `schema/0`. Default JSON serialization provided. No implementations yet --
  behaviour defined for when RPC use cases arise.

- **Atom `event_type` support in aggregates**: `evoq_aggregate:append_events/5`
  now auto-converts atom `event_type` values to binary for storage via
  `resolve_event_type/1`. Typed event modules can return atom `event_type` in
  `to_map/1` (e.g., `venture_initiated_v1`) and evoq stores it as binary
  (`<<"venture_initiated_v1">>`). Binary values pass through unchanged.

- **Artifacts guide**: New `guides/artifacts.md` documenting the 4 artifact types
  (command, event, fact, hope), when to use each, and reference implementations.

## [1.9.2] - 2026-03-12

### Fixed

- **`evoq_projection`: Per-projection `store_id` for replay**. Projections that
  replay events on rebuild used a global `application:get_env(evoq, store_id)`
  which defaults to `default_store`. In multi-store systems (e.g. one store per
  bounded context), this caused projections to replay from the wrong store —
  or a non-existent one — resulting in empty read models after restart.
  Projections now accept `store_id` in Opts (3rd argument to `start_link/3`),
  which takes precedence over the global app env during replay.

## [1.9.1] - 2026-03-08

### Added

- **`evoq_event_store:has_events/1`**: Check if a store contains at least one event.
  Delegates to adapter's `has_events/1` if available, falls back to reading 1 event
  via `read_all_global`.
- **Catch-up diagnostic logging**: `evoq_store_subscription` now logs each event's
  type and handler count during historical replay for troubleshooting.

## [1.9.0] - 2026-03-06

### Added

- **Catch-up historical replay**: `evoq_store_subscription` now replays all historical
  events from the store before subscribing to new events. Uses `read_all_global/3`
  to read events in batches, routing through the same path as live events.
- **`evoq_event_store:read_all_global/3`**: Read all events across all streams in
  global order with offset/batch pagination. Falls back to `read_all_events/2` if
  adapter does not implement the optional callback.

## [1.8.2] - 2026-03-08

### Fixed

- **`evoq_store_subscription`: Cross-stream checkpoint collision with `$all` subscriptions**.
  The `$all` subscription delivers events from multiple streams, but stream-local
  versions overlap (stream A version 0, stream B version 0). When these were passed
  to `evoq_projection` as the `version` in metadata, the idempotency check
  `EventVersion =< Checkpoint` incorrectly skipped events from the second stream.
  Now maintains a monotonically increasing sequence counter per subscription instance.
  The global sequence is injected as `version` in metadata (for projection checkpoints),
  and the original stream version is preserved as `stream_version`.

- **Test infrastructure**: Added `evoq_type_provider` to test helper
  `ensure_routing_infrastructure/0`, preventing ETS table crashes when
  `evoq_event_router` attempts upcasting during tests.

## [1.8.1] - 2026-03-07

### Fixed

- **Projection checkpoint skips first event (version 0)**: Initial checkpoint
  was 0, and the idempotency check `EventVersion =< Checkpoint` skipped events
  at version 0. Since ReckonDB stream versions are 0-based, the first event in
  every stream was silently dropped. Changed initial checkpoint to -1 (sentinel
  for "nothing processed yet"). Same fix applied to `do_rebuild/1`. This is the
  same class of bug that was fixed in aggregates in v1.3.1.

## [1.8.0] - 2026-03-07

### Changed

- **`evoq_store_subscription`: Single `$all` subscription for global ordering**.
  Previously created N independent per-event-type subscriptions to ReckonDB,
  one per registered handler type. Each subscription had its own bridge process,
  so events of different types had no ordering guarantee relative to each other.
  Now uses a single `by_stream` subscription with `<<"$all">>` selector, receiving
  ALL events in global store order. Events are filtered locally by checking
  `evoq_event_type_registry:get_handlers/1` — types with no handlers are skipped.
  This fixes race conditions where causally related events of different types
  (e.g., `license_initiated_v1` before `license_published_v1`) could be delivered
  out of order to their respective projections.

## [1.7.0] - 2026-03-07

### Changed

- **`evoq_read_model_ets` shared named tables**: Named ETS tables now support
  multiple projections writing to the same read model. If a named table already
  exists, new instances join it instead of crashing. This enables the vertical
  slicing pattern where each projection (desk) handles one event type but all
  project into the same read model. Anonymous (unnamed) tables remain isolated
  per instance as before.

## [1.6.0] - 2026-03-07

### Added

- **`evoq_store_subscription` module**: Bridge between event stores and evoq's
  routing infrastructure. Creates per-event-type subscriptions to a reckon-db
  store, matching evoq's event-type-oriented architecture. Only events that have
  registered handlers/projections/PMs are subscribed to — filtering happens at
  the store level, not the application level. This is the critical missing link
  that connects the event store to evoq behaviours (`evoq_event_handler`,
  `evoq_projection`, `evoq_process_manager`).
  - Start one instance per store: `evoq_store_subscription:start_link(my_store)`
  - Automatically discovers registered event types from `evoq_event_type_registry`
  - Dynamically subscribes to new event types as handlers register
  - Routes events to both `evoq_event_router` and `evoq_pm_router`

- **`evoq_event_type_registry:register_listener/1`**: Atomically returns all
  currently registered event types AND subscribes the caller for future
  type registration notifications. Race-free — no `register/2` call can
  execute between returning types and subscribing for notifications.

- **`evoq_event_type_registry:unregister_listener/1`**: Removes a store
  subscription listener.

### Changed

- **`evoq_event_type_registry:register/2`**: Now detects when an event type
  gets its first handler and notifies registered store subscription listeners
  via `{new_event_type, EventType}` messages.

## [1.5.0] - 2026-03-05

### Fixed

- **Nested event structure in `append_events`**: Events produced by aggregates
  now use proper nested `#{event_type, data, metadata}` structure.

## [1.4.0] - 2026-02-25

### Added

- **`evoq_subscriptions` facade module**: Application-level API for subscription
  operations, mirroring the `evoq_event_store` pattern. Application code should call
  `evoq_subscriptions:subscribe/5` instead of the adapter directly. Delegates to a
  configured `subscription_adapter` (set via `{evoq, [{subscription_adapter, Module}]}`).
  Exports: `subscribe/5`, `unsubscribe/2`, `ack/4`, `get_checkpoint/2`, `list/1`,
  `get_by_name/2`, `get_adapter/0`, `set_adapter/1`.

## [1.3.1] - 2026-02-13

### Fixed

- **Aggregate replay at version 0**: `load_or_init/3` now uses `State =/= undefined`
  instead of `Version > 0` to detect replayed events. The first event in a stream
  is version 0, so the previous guard skipped it and re-initialized fresh.

### Added

- **`event_to_map/1` exported**: `evoq_event_store:event_to_map/1` is now public API.
  Converts `#evoq_event{}` records to flat maps, merging business data from the `data`
  field into the top level so aggregates see consistent shapes regardless of source.

## [1.3.0] - 2026-02-11

### Added

- **`idempotency_key` field on `#evoq_command{}`**: Optional caller-provided key for
  deterministic command deduplication. When set, the idempotency cache uses this key
  instead of `command_id`. Use for scenarios like "user cannot submit the same form twice"
  where the deduplication key should be deterministic and intent-based.

- **Auto-generated `command_id`**: The dispatcher now auto-generates `command_id` via
  `crypto:strong_rand_bytes/1` if the field is `undefined`. Callers no longer need to
  generate their own command IDs — the framework handles it.

- **`evoq_command:ensure_id/1`**: Fills in `command_id` if undefined, returns command
  unchanged if already set.

- **`evoq_command:get_idempotency_key/1`** and **`set_idempotency_key/2`**: Accessors
  for the new `idempotency_key` field.

### Changed

- **Idempotency cache key selection**: The dispatcher now uses `idempotency_key` (if set)
  for cache lookups, falling back to `command_id`. This separates the concerns of command
  identification (tracing, unique per invocation) from command deduplication (deterministic
  per intent).

- **Validation relaxed**: `evoq_command:validate/1` no longer rejects commands with
  `undefined` command_id, since the dispatcher auto-generates it before execution.

### Migration

- **No breaking changes for existing code.** Commands with manually-set `command_id` continue
  to work exactly as before. The new `idempotency_key` field defaults to `undefined`.
- **Recommended**: Stop generating `command_id` manually in dispatch modules. Let the
  framework handle it. If you need deduplication, use `idempotency_key` instead.

## [1.2.1] - 2026-02-01

### Added

- **Event Envelope Documentation**: Comprehensive guide explaining `evoq_event` record structure
  - New guide: `guides/event_envelope.md` - Complete explanation of envelope fields
  - New diagram: `assets/event-envelope-diagram.svg` - Visual event lifecycle
  - Updated `guides/projections.md` - Clarified envelope structure in projections
  - Documents where business event payloads fit (`data` field)
  - Explains metadata usage (correlation_id, causation_id, etc.)
  - Event naming conventions and versioning patterns
  - Common mistakes to avoid

### Documentation

- Improved clarity on event envelope structure
- Added visual diagrams for event lifecycle
- Standardized metadata field documentation

## [1.2.0] - 2026-01-21

### Added

- **Tag-Based Querying**: Cross-stream event queries using tags
  - `tags` field added to `#evoq_event{}` record in `evoq_types.hrl`
  - `evoq_tag_match()` type - Support for `any` (union) and `all` (intersection) matching
  - `tags` subscription type for tag-based subscriptions
  - Tags are for QUERY purposes only, NOT for concurrency control

## [1.1.3] - 2026-01-19

### Fixed

- **Documentation**: Minor documentation improvements

## [1.1.0] - 2026-01-08

### Added

- **Bit Flags Module** (`evoq_bit_flags`): Efficient bitwise flag manipulation for aggregate state
  - `set/2`, `unset/2`: Set/unset single flags
  - `set_all/2`, `unset_all/2`: Set/unset multiple flags
  - `has/2`, `has_not/2`: Check single flag state
  - `has_all/2`, `has_any/2`: Check multiple flags
  - `to_list/2`, `to_string/2,3`: Human-readable conversions with flag maps
  - `decompose/1`: Extract power-of-2 components
  - `highest/2`, `lowest/2`: Get highest/lowest set flag description

- **Bit Flags Guide** (`guides/bit_flags.md`): Comprehensive documentation
  - Why use bit flags in event sourcing
  - Core operations with examples
  - Aggregate state management patterns
  - Best practices for flag definition
  - Complete function reference

### Changed

- Aggregate status fields should now use integer bit flags instead of atoms
  for better memory efficiency, query performance, and event store compatibility

## [1.0.3] - 2026-01-06

### Fixed

- **Macro guard compatibility**: Added `-ifndef` guards around macro definitions
  in `evoq_types.hrl` to prevent redefinition errors when used alongside
  `esdb_gater_types.hrl` in adapters like reckon_evoq

## [1.0.2] - 2026-01-06

### Changed

- **Independence from reckon_gater**: Removed direct dependency on reckon_gater
  - Introduced `include/evoq_types.hrl` with evoq's own type definitions
  - Adapters (like reckon_evoq) now handle type translation between evoq and backend
  - evoq is now a pure CQRS/ES framework without storage backend coupling

### Fixed

- **hex.pm dependencies**: Package now correctly publishes with only telemetry as dependency

## [1.0.1] - 2026-01-03

### Fixed

- **SVG diagrams**: Updated architecture.svg, command-dispatch.svg, and event-routing.svg to reference reckon-db instead of erl-esdb

## [1.0.0] - 2026-01-03

### Changed

- **Stable Release**: First stable release of evoq under reckon-db-org
- All APIs considered stable and ready for production use
- Fixed documentation links (guides/adapters.md)
- Updated dependency references to reckon_gater

## [0.3.0] - 2025-12-20

### Added

- **Documentation**: Comprehensive educational guides with SVG diagrams
  - Architecture overview guide with system diagram
  - Aggregates guide with lifecycle diagram
  - Event handlers guide with routing diagram
  - Process managers guide with saga flow diagram
  - Projections guide with data flow diagram
  - Adapters guide for event store integration
- **ex_doc integration**: Full hex.pm documentation support via rebar3_ex_doc

### Changed

- **Dependencies**: Updated reckon_gater from 0.3.0 to 0.4.3

### Fixed

- **EDoc errors**: Fixed XML parsing issues in memory monitor documentation
- **EDoc errors**: Removed invalid @doc tags before -callback declarations

## [0.2.0] - 2024-12-19

### Added

- **Event Store Adapter Pattern**: Pluggable event store backends
  - `evoq_adapter` behavior for custom adapters
  - `evoq_event_store` facade with adapter delegation
  - Support for erl-esdb-gater integration

- **Checkpoint Store**: Persistent checkpoint tracking
  - `evoq_checkpoint_store` behavior
  - `evoq_checkpoint_store_ets` ETS-based implementation
  - Position tracking for projections and handlers

- **Dead Letter Queue**: Failed event handling
  - `evoq_dead_letter` for events that exhaust retries
  - List, retry, and discard operations
  - Telemetry integration for monitoring

- **Error Handling**: Comprehensive error management
  - `evoq_error_handler` for centralized error processing
  - Failure context tracking via `evoq_failure_context`
  - Retry strategies with backoff

### Changed

- **Event Router**: Switched to per-event-type subscriptions
  - Handlers declare `interested_in/0` for event types
  - Prevents subscription explosion with many aggregates
  - Constant memory usage regardless of aggregate count

## [0.1.0] - 2024-12-18

### Added

- Initial release of evoq CQRS/Event Sourcing framework

- **Aggregates** (`evoq_aggregate`):
  - `evoq_aggregate` behavior with init/execute/apply callbacks
  - Partitioned supervision across 4 supervisors
  - Configurable TTL and idle timeout
  - Snapshot support for faster loading
  - Memory pressure monitoring with adaptive TTL

- **Aggregate Lifespan** (`evoq_aggregate_lifespan`):
  - Configurable lifecycle management
  - Default 30-minute idle timeout
  - Hibernate after 1 minute idle
  - Snapshot on passivation

- **Command Dispatch** (`evoq_dispatcher`):
  - Command routing to aggregates
  - Middleware pipeline support
  - Consistency mode (strong/eventual)

- **Middleware** (`evoq_middleware`):
  - Pluggable command pipeline
  - Validation middleware
  - Idempotency middleware
  - Consistency middleware

- **Event Handlers** (`evoq_event_handler`):
  - Per-event-type subscriptions
  - Retry strategies with exponential backoff
  - Dead letter queue for failed events
  - Strong/eventual consistency modes

- **Process Managers** (`evoq_process_manager`):
  - Long-running business process coordination
  - Event correlation and routing
  - Command dispatch from handlers
  - Compensation support for failures

- **Projections** (`evoq_projection`):
  - Read model builders from events
  - Checkpointing for resume
  - Rebuild capability
  - Multiple storage backends

- **Event Upcasters** (`evoq_event_upcaster`):
  - Schema evolution support
  - Event migration on replay

- **Memory Monitor** (`evoq_memory_monitor`):
  - System memory pressure detection
  - Adaptive TTL adjustment
  - Aggregate eviction under pressure

- **Telemetry Integration**:
  - Comprehensive event emission
  - Aggregate lifecycle events
  - Handler processing events
  - Projection progress events

### Dependencies

- erl_esdb_gater 0.3.0 - Gateway API and shared types
- telemetry 1.3.0 - Observability

