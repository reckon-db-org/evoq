# Changelog

All notable changes to evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

