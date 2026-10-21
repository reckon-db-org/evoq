# Adapters

evoq uses an adapter pattern to integrate with different event store backends. This guide explains how to configure and implement adapters.

## Overview

evoq doesn't include any specific event store implementation. Instead, it defines adapter behaviors that must be implemented to connect to your chosen backend.

```text
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│    evoq     │────>│   Adapter       │────>│  Event Store    │
│  (Framework)    │     │ (Interface)     │     │   (Backend)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

## Available Adapters

### reckon_evoq (Recommended)

The `reckon_evoq_adapter` (from [reckon_evoq](https://hex.pm/packages/reckon_evoq)) connects to reckon-db through reckon_gater.

Add to your dependencies:

```erlang
{deps, [
    {evoq, "~> 1.27"},
    {reckon_evoq, "~> 2.8"}
]}.
```

Configure in `sys.config`:

```erlang
{evoq, [
    {event_store_adapter, reckon_evoq_adapter},
    {store_id, my_store}
]}
```

## Adapter Behaviors

evoq defines three adapter behaviors:

### evoq_adapter (Event Store)

Core event operations:

```erlang
%% The core of evoq_adapter. The behaviour module (src/evoq_adapter.erl)
%% carries the full contract, including the batch-limited reads
%% (read_by_event_types/3, read_by_tags/4, ccc_read_by_payload/4) and the
%% payload index introspection a CCC decision needs.
-callback append(StoreId :: atom(), StreamId :: binary(),
                 ExpectedVersion :: integer(), Events :: [map()]) ->
    {ok, non_neg_integer()} | {error, term()}.
-callback read(StoreId :: atom(), StreamId :: binary(),
               StartVersion :: non_neg_integer(), Count :: pos_integer(),
               Direction :: forward | backward) ->
    {ok, [map()]} | {error, term()}.
-callback read_all(StoreId :: atom(), StreamId :: binary(),
                   Direction :: forward | backward) ->
    {ok, [map()]} | {error, term()}.
-callback version(StoreId :: atom(), StreamId :: binary()) -> integer().
-callback exists(StoreId :: atom(), StreamId :: binary()) -> boolean().
-callback list_streams(StoreId :: atom()) -> {ok, [binary()]} | {error, term()}.
-callback delete_stream(StoreId :: atom(), StreamId :: binary()) ->
    ok | {error, term()}.
%% Optional: see "Minting a stream id" below.
-callback new_stream_id(Prefix :: atom() | binary()) -> binary().
```

### Minting a stream id

A stream id's format is the store's contract, not evoq's, so evoq does not
mint one itself. `new_stream_id/1` is an **optional** `evoq_adapter`
callback: an adapter that can mint implements it (in reckon-db it
delegates to `reckon_gater_stream_id:new/1`, producing a time-sortable
`<prefix>-<32 lowercase hex>` id), and callers reach it through one evoq
call:

```erlang
GameId = evoq_event_store:new_stream_id(game).
```

Use it rather than reaching past evoq to the store layer for an id: the
format then has one definition, in the adapter, and a service that needs a
fresh aggregate id touches evoq and nothing below it.

An adapter written before this callback existed keeps working. A caller
that asks one to mint gets `{adapter_cannot_mint_stream_ids, Adapter}`,
naming the adapter that cannot, rather than an `undef` somewhere under the
caller's command handler.

### evoq_snapshot_adapter

Snapshot operations for aggregate optimization:

```erlang
-callback save(StoreId :: atom(), StreamId :: binary(),
               Version :: non_neg_integer(), Data :: map() | binary(),
               Metadata :: map()) ->
    ok | {error, term()}.
-callback read(StoreId :: atom(), StreamId :: binary()) ->
    {ok, map()} | {error, not_found | term()}.
-callback read_at_version(StoreId :: atom(), StreamId :: binary(),
                          Version :: non_neg_integer()) ->
    {ok, map()} | {error, not_found | term()}.
-callback delete(StoreId :: atom(), StreamId :: binary()) -> ok | {error, term()}.
-callback delete_at_version(StoreId :: atom(), StreamId :: binary(),
                            Version :: non_neg_integer()) ->
    ok | {error, term()}.
-callback list_versions(StoreId :: atom(), StreamId :: binary()) ->
    {ok, [non_neg_integer()]} | {error, term()}.
```

### evoq_subscription_adapter

Subscription operations for event delivery:

```erlang
%% Type is one of stream_id, event_type, pattern or all, as the store
%% backend defines them; see src/evoq_subscription_adapter.erl.
-callback subscribe(StoreId :: atom(), Type :: atom(),
                    Selector :: binary() | map(),
                    SubscriptionName :: binary(), Opts :: map()) ->
    {ok, SubscriptionId :: binary()} | {error, term()}.
-callback unsubscribe(StoreId :: atom(), SubscriptionId :: binary()) ->
    ok | {error, term()}.
-callback ack(StoreId :: atom(), SubscriptionName :: binary(),
              StreamId :: binary() | undefined, Position :: non_neg_integer()) ->
    ok | {error, term()}.
-callback get_checkpoint(StoreId :: atom(), SubscriptionName :: binary()) ->
    {ok, non_neg_integer()} | {error, not_found | term()}.
-callback list(StoreId :: atom()) -> {ok, [map()]} | {error, term()}.
-callback get_by_name(StoreId :: atom(), SubscriptionName :: binary()) ->
    {ok, map()} | {error, not_found | term()}.
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

%% evoq_adapter callbacks: append/4, read/5, read_all/3, version/2,
%% exists/2, list_streams/1, delete_stream/2
%% evoq_snapshot_adapter callbacks: save/5, read/2, read_at_version/3,
%% delete/2, delete_at_version/3, list_versions/2
%% evoq_subscription_adapter callbacks: subscribe/5, unsubscribe/2, ack/4,
%% get_checkpoint/2, list/1, get_by_name/2
%% A module exports every callback it implements; export each one as you
%% write it. Only append/4 is written out here.
-export([append/4]).

%% Implementation...
append(_StoreId, _StreamId, ExpectedVersion, Events) ->
    %% Connect to your event store and append the events, then answer the
    %% stream's new version. Versions are 0-based, and -1 means "the stream
    %% must not exist yet", so an append of N events ends at N - 1 there.
    {ok, ExpectedVersion + length(Events)}.

%% ... implement other callbacks
```

## Configuration

Full adapter configuration options:

```erlang
{evoq, [
    %% Required: which adapter to use
    {event_store_adapter, reckon_evoq_adapter},

    %% Store identifier (passed to adapter)
    {store_id, my_store},

    %% Optional: separate adapters for snapshots/subscriptions
    {snapshot_store_adapter, reckon_evoq_adapter},
    {subscription_adapter, reckon_evoq_adapter}
]}
```

## Local Development

For local development, use `_checkouts` to link adapters:

```bash
mkdir -p _checkouts
ln -s /path/to/reckon-evoq _checkouts/reckon_evoq
```

This allows modifying the adapter code alongside your application.

## Testing with Mocks

Use `meck` to mock adapters in tests:

```erlang
my_test() ->
    meck:new(reckon_evoq_adapter, [passthrough]),
    meck:expect(reckon_evoq_adapter, append, fun(_, _, _, Events) ->
        {ok, length(Events)}
    end),

    %% Run your test
    ok = my_module:do_something(),

    meck:unload(reckon_evoq_adapter).
```

## See Also

- [Architecture](architecture.md) - How adapters fit into the overall system
- [reckon_evoq](https://hex.pm/packages/reckon_evoq) - Adapter from evoq to reckon-db
- [reckon-db](https://hex.pm/packages/reckon_db) - BEAM-native event store
