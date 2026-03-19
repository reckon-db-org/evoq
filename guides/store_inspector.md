# Store Inspector

The `evoq_store_inspector` module provides store-level introspection for debugging and monitoring. It delegates to the configured event store adapter (e.g., `reckon_evoq_adapter`).

## Functions

### store_stats/1

Aggregate statistics: stream count, total events, snapshot count, subscription count.

```erlang
{ok, Stats} = evoq_store_inspector:store_stats(my_store).
%% #{store_id => my_store, stream_count => 42, total_events => 1337,
%%   snapshot_count => 5, subscription_count => 3, has_events => true}
```

### list_all_snapshots/1

All snapshots across all streams, sorted newest first (summaries without data payloads).

```erlang
{ok, Snapshots} = evoq_store_inspector:list_all_snapshots(my_store).
```

### list_subscriptions/1

All active subscriptions with checkpoint positions.

```erlang
{ok, Subs} = evoq_store_inspector:list_subscriptions(my_store).
```

### subscription_lag/2

How many events behind a specific subscription is.

```erlang
{ok, Lag} = evoq_store_inspector:subscription_lag(my_store, <<"prj_users">>).
%% #{subscription_name => ..., checkpoint => 42, latest_position => 100, lag_events => 57}
```

### event_type_summary/1

Census of event types with counts. Can be expensive for large stores.

```erlang
{ok, Types} = evoq_store_inspector:event_type_summary(my_store).
```

### stream_info/2

Detailed info for a single stream: version, timestamps, snapshot coverage.

```erlang
{ok, Info} = evoq_store_inspector:stream_info(my_store, <<"user-123">>).
```

## Architecture

![Store Inspector](assets/store_inspector.svg)

The inspector delegates to the configured adapter via `evoq_event_store:get_adapter/0`. If the adapter doesn't implement a given function, `{error, {not_supported, Fun}}` is returned.

The full chain: `evoq_store_inspector` -> `reckon_evoq_adapter` -> `esdb_gater_api` (load-balanced) -> `reckon_db_gateway_worker` -> `reckon_db_store_inspector`.
