# Adapters

evoq uses an adapter pattern to integrate with different event store backends. This guide explains how to configure and implement adapters.

## Overview

evoq doesn't include any specific event store implementation. Instead, it defines adapter behaviors that must be implemented to connect to your chosen backend.

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    evoq     │────>│   Adapter       │────>│  Event Store    │
│  (Framework)    │     │ (Interface)     │     │   (Backend)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

## Available Adapters

### reckon-db-gater (Recommended)

The `evoq_esdb_gater_adapter` connects to reckon-db via the gateway protocol.

Add to your dependencies:

```erlang
{deps, [
    {evoq, "0.2.0"},
    {reckon_db_gater, "0.4.3"}
]}.
```

Configure in `sys.config`:

```erlang
{evoq, [
    {event_store_adapter, evoq_esdb_gater_adapter},
    {store_id, my_store}
]}
```

## Adapter Behaviors

evoq defines three adapter behaviors:

### evoq_adapter (Event Store)

Core event operations:

```erlang
-callback append(StoreId, StreamId, ExpectedVersion, Events) -> {ok, Version} | {error, Reason}.
-callback read(StoreId, StreamId, StartVersion, Count, Direction) -> {ok, Events} | {error, Reason}.
-callback read_all(StoreId, StreamId, Direction) -> {ok, Events} | {error, Reason}.
-callback version(StoreId, StreamId) -> integer().
-callback exists(StoreId, StreamId) -> boolean().
-callback list_streams(StoreId) -> {ok, [StreamId]} | {error, Reason}.
-callback delete_stream(StoreId, StreamId) -> ok | {error, Reason}.
```

### evoq_snapshot_adapter

Snapshot operations for aggregate optimization:

```erlang
-callback save(StoreId, StreamId, Version, Data, Metadata) -> ok | {error, Reason}.
-callback read(StoreId, StreamId) -> {ok, Snapshot} | {error, not_found}.
-callback read_at_version(StoreId, StreamId, Version) -> {ok, Snapshot} | {error, not_found}.
-callback delete(StoreId, StreamId) -> ok | {error, Reason}.
-callback list_versions(StoreId, StreamId) -> {ok, [Version]} | {error, Reason}.
```

### evoq_subscription_adapter

Subscription operations for event delivery:

```erlang
-callback subscribe(StoreId, Type, Selector, Name, Opts) -> {ok, SubscriptionId} | {error, Reason}.
-callback unsubscribe(StoreId, SubscriptionId) -> ok | {error, Reason}.
-callback ack(StoreId, Name, StreamId, Position) -> ok | {error, Reason}.
-callback get_checkpoint(StoreId, Name) -> {ok, Position} | {error, not_found}.
-callback list(StoreId) -> {ok, [Subscription]} | {error, Reason}.
```

## Implementing a Custom Adapter

To implement a custom adapter:

1. Create a module that implements `evoq_adapter` (required)
2. Optionally implement `evoq_snapshot_adapter` and `evoq_subscription_adapter`
3. Configure evoq to use your adapter

Example skeleton:

```erlang
-module(my_custom_adapter).
-behaviour(evoq_adapter).
-behaviour(evoq_snapshot_adapter).
-behaviour(evoq_subscription_adapter).

%% evoq_adapter callbacks
-export([append/4, read/5, read_all/3, version/2, exists/2, list_streams/1, delete_stream/2]).

%% evoq_snapshot_adapter callbacks
-export([save/5, read/2, read_at_version/3, delete/2, list_versions/2]).

%% evoq_subscription_adapter callbacks
-export([subscribe/5, unsubscribe/2, ack/4, get_checkpoint/2, list/1]).

%% Implementation...
append(StoreId, StreamId, ExpectedVersion, Events) ->
    %% Connect to your event store and append events
    {ok, NewVersion}.

%% ... implement other callbacks
```

## Configuration

Full adapter configuration options:

```erlang
{evoq, [
    %% Required: which adapter to use
    {event_store_adapter, evoq_esdb_gater_adapter},

    %% Store identifier (passed to adapter)
    {store_id, my_store},

    %% Optional: separate adapters for snapshots/subscriptions
    {snapshot_adapter, evoq_esdb_gater_snapshot_adapter},
    {subscription_adapter, evoq_esdb_gater_subscription_adapter}
]}
```

## Local Development

For local development, use `_checkouts` to link adapters:

```bash
mkdir -p _checkouts
ln -s /path/to/reckon-db-gater _checkouts/reckon_db_gater
```

This allows modifying the adapter code alongside your application.

## Testing with Mocks

Use `meck` to mock adapters in tests:

```erlang
my_test() ->
    meck:new(evoq_esdb_gater_adapter, [passthrough]),
    meck:expect(evoq_esdb_gater_adapter, append, fun(_, _, _, Events) ->
        {ok, length(Events)}
    end),

    %% Run your test
    ok = my_module:do_something(),

    meck:unload(evoq_esdb_gater_adapter).
```

## See Also

- [Architecture](architecture.md) - How adapters fit into the overall system
- [reckon-db-gater](https://hex.pm/packages/reckon_db_gater) - Gateway adapter for reckon-db
- [reckon-db](https://hex.pm/packages/reckon_db) - BEAM-native event store
