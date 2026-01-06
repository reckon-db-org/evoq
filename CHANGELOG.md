# Changelog

All notable changes to evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

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

