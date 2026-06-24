# PROPOSAL: CCC payload conditions + the stateful Decision/Context actor

**Status:** Draft
**Author:** Raf Lefever
**Date:** 2026-06-24
**Related:**
- `evoq_decision` / `evoq_decision_runtime` (existing DCB Decision behaviour)
- reckon-db CCC payload indexes (reckon_db 5.5.1+, reckon-gater 3.7.0+)
- [reckon-gater CCC guide](https://codeberg.org/reckon-db-org/reckon-gater/src/branch/main/guides/ccc.md)
- DCB specification — https://dcb.events/

---

## Summary

Two additive, opt-in extensions to evoq's write side:

- **Part A — CCC payload conditions.** Extend `evoq_decision`'s `context_filter()`
  (and the runtime + the `evoq_event_store` adapter) with `{payload_match, Key, Value}`
  and `{payload_hash_match, Keys, Values}`, so a Decision's consistency boundary can
  query **opaque event-data fields** (declared payload indexes) without the producer
  having to tag at write time. DCB is already implemented by `evoq_decision`; this adds
  the CCC dimension reckon-db now supports.

- **Part B — the stateful Decision/Context actor.** An **optional** per-node `gen_server`
  mode for `evoq_decision`, keyed on a decision-declared **boundary key**, reusing the
  exact aggregate process machinery (`evoq_aggregate_partition_sup`, the pg registry,
  the lifespan/TTL system). It caches the folded decision model and serialises commands
  for a hot boundary, the same way `evoq_aggregate` caches folded state and serialises
  commands for a stream. It is a contention-reducer and cache, **never** the correctness
  authority — the store's in-transaction append condition stays authoritative.

Both are backwards-compatible. No existing decision changes behaviour.

---

## Background: where evoq already is

`evoq_decision` is a faithful **Dynamic Consistency Boundary** implementation, matching
the dcb.events spec and Axon Framework 5's model:

| DCB spec | `evoq_decision` |
|----------|-----------------|
| `query` (types + tags) | `context/1 -> context_filter()` |
| Decision Model (project events) | `decide(ContextEvents, Command)` |
| `AppendCondition{failIfEventsMatch, after}` | `append_if_no_tag_matches(Filter, SeqCutoff, Events)` |
| conflict → rebuild → retry | `{error, {context_changed, _}}` retry loop in `evoq_decision_runtime` |

Two facts about the current implementation drive this proposal:

1. **No payload conditions.** `context_filter()` is `any_of | all_of | event_type | and_ | or_`
   — tag/type only. The DCB spec, Axon, Marten, and every reference event store are the
   same: event data is opaque to the query. reckon-db's CCC payload indexes
   (`payload_match` / `payload_hash_match`) are an extension *beyond* the spec, and evoq
   can't express them yet.

2. **The aggregate process is a per-node cache, not a cluster singleton.**
   `evoq_aggregate_registry:lookup/1` filters to `node(Pid) =:= node()` — each node may
   hold its own aggregate process for the same id. Cluster-wide correctness comes from
   reckon-db's **stream version check at append**, not from the process being unique.
   The process exists to (a) cache folded state and (b) serialise same-node commands so
   the optimistic check usually passes first try.

Fact 2 is the unlock for Part B: a Decision/Context actor can use the *identical* model —
a per-node cache+serialiser whose correctness backstop is the store's append condition.

---

## Part A — CCC payload conditions

### Behaviour change (`evoq_decision`)

Extend the type and document the new variants:

```erlang
-type context_filter() ::
      {any_of, [binary()]}
    | {all_of, [binary()]}
    | {event_type, binary()}
    %% CCC — require the store to declare the matching payload index
    | {payload_match, Key :: binary(), Value :: binary()}
    | {payload_hash_match, Keys :: [binary()], Values :: [binary()]}
    | {and_, [context_filter()]}
    | {or_,  [context_filter()]}.
```

### Adapter change (`evoq_event_store`)

Add two reads to the adapter contract (reckon_evoq implements them by delegating to
`reckon_gater_api:ccc_read_by_payload/4` and `ccc_read_by_payload_hash/4`):

```erlang
-callback ccc_read_by_payload(StoreId, Key, Value, BatchSize) ->
    {ok, [event()]} | {error, term()}.
-callback ccc_read_by_payload_hash(StoreId, Keys, Values, BatchSize) ->
    {ok, [event()]} | {error, term()}.
```

`append_if_no_tag_matches/4` already accepts the full filter algebra, and reckon-db's
in-transaction check already evaluates payload filters atomically — so the **write/condition
side needs no adapter change**, only the context **read** side.

### Runtime change (`evoq_decision_runtime`)

The read path (today: `read_by_tags` / `read_by_event_types`, intersected/unioned
client-side) gains payload branches:

- `{payload_match, K, V}` → `ccc_read_by_payload(StoreId, K, V, Batch)`
- `{payload_hash_match, Ks, Vs}` → `ccc_read_by_payload_hash(StoreId, Ks, Vs, Batch)`
- compound `and_`/`or_` mixing tag/type/payload → read each dimension, combine
  (intersect for `and_`, union for `or_`), then pass to `decide/2`. The append uses the
  composed filter verbatim; the store's atomic check is the authority, so client-side
  combination only has to be a correct *superset* for the read.

### Graceful degradation (required)

CCC payload reads need reckon-gater ≥ 3.7 (introspection) and reckon-db ≥ 5.3 (the index).
A decision using payload filters against an older store must fail **loudly and early**
(`{error, {payload_index_unavailable, Filter}}`), never silently return `[]` and let a
bad decision through. Mirror the gateway UI's discovery fallback: detect `rpc_failed` /
undeclared index and surface it.

### v1 limitations to close while here

- The `or_` compound-filter superset bug documented in `evoq_decision` (a pure
  `event_type` branch inside `or_` can miss events) — payload branches make this worse;
  fix the runtime to read every branch fully.
- The `_dcb`-pseudo-stream-only restriction — confirm payload reads cover the same scope.

---

## Part B — the stateful Decision/Context actor (the core question)

> Could/should a `{Dcb,Ccc}Context` be a long-lived gen_server like the aggregate?

**Yes — as an opt-in mode for boundaries that are *keyed and hot*, reusing the aggregate
machinery. No — as a blanket replacement of the stateless runtime.**

### The unifying frame: aggregate = the static special case of a boundary

The DCB spec states aggregates are a special case of DCB. evoq can make that literal:

| | boundary | key | append condition | writer |
|---|---|---|---|---|
| `evoq_aggregate` | one stream | stream id | stream version | sole, by construction |
| `evoq_decision` (stateless) | ad-hoc query | — | `failIfEventsMatch(query, after)` | many |
| `evoq_decision` (**stateful, Part B**) | resolved query value | declared `boundary_key` | `failIfEventsMatch(query, after)` | many; one *cached* per node |

A stateful decision is "a transient aggregate for a dynamic boundary": materialise the
boundary as an actor on demand, fold its context once, serialise commands against it,
evict when it goes cold.

### Why it makes sense (the wins, identical to the aggregate's)

For a **keyed, contended** boundary (seat reservation per seat, balance per account,
allocation per SKU):

1. **Serialise → kill optimistic thrash.** 100 commands for the same seat queue at one
   process and execute in order; the append condition passes first try each time instead
   of N−1 `context_changed` retries.
2. **Cache the decision model.** Hold the folded decision data (current reservations for
   this seat / current balance) and update it incrementally after each successful append
   — no full context re-read per command. Exactly `evoq_aggregate`'s folded-state cache.
3. **Free ordering, backpressure, idempotency.** Mailbox gives ordering; an idempotency
   key can be deduped in actor state cheaply.

### Why it must stay opt-in (the costs)

1. **Correctness is still the store's job, not the actor's.** Like the aggregate (which
   is per-node, not a singleton — see Fact 2), the actor is a same-node optimisation. A
   second node, a different decision sharing the boundary's tags, or a direct append can
   still write. So `append_if_no_tag_matches` remains the **sole authority**; on
   `context_changed` the actor invalidates its cache, re-reads context, and retries. The
   actor never gets to "trust" its cache as truth.
2. **Cache-hit value scales with boundary ownership.** The aggregate's cache is almost
   always fresh because streams are disjoint and it's effectively the only same-node
   writer. A decision boundary keyed on a single disjoint dimension (one seat, one
   account) is nearly as good. A boundary keyed on a tag **shared** with other decisions
   goes stale more often → more re-reads. Still serialises; just less cache benefit.
3. **Cold / one-shot / un-keyable decisions should NOT spawn a process.** Email-uniqueness
   on registration is checked once per email, never again — spawning a gen_server,
   folding context, idling, and TTL-evicting is pure overhead versus a single
   read-decide-append. Compound boundaries with no natural partition key likewise have no
   sensible actor identity.

### Design

Add **optional** callbacks to `evoq_decision`:

```erlang
%% Opt into the stateful actor by returning a stable partition key for the
%% command's consistency boundary. `undefined` (or callback absent) => the
%% stateless optimistic runtime (current behaviour).
-callback boundary_key(Command :: map()) -> binary() | undefined.

%% Optional folded decision model (mirrors aggregate init/apply). When
%% present, decide/2 receives the folded Model instead of raw ContextEvents.
-callback init_decision_model() -> Model :: term().
-callback apply_context_event(Model :: term(), Event :: map()) -> Model :: term().

-optional_callbacks([boundary_key/1, init_decision_model/0, apply_context_event/2,
                     retry_budget/0]).
```

Dispatch (in `evoq_decision_runtime` / a thin `evoq_decision` facade):

```
boundary_key(Cmd) == undefined  -> run_stateless(Module, Cmd)       % today's path
boundary_key(Cmd) == Key        -> Pid = get_or_start({decision, Module, Key}),
                                   gen_server:call(Pid, {decide, Cmd})
```

The actor (`evoq_decision_actor`, a `gen_server` started under the **existing**
`evoq_aggregate_partition_sup`, registered in the **existing** pg registry under group
`{decision, Module, Key}`, TTL via the **existing** `evoq_aggregate_lifespan`):

- **init** — run `context/1`'s query once via the adapter (tag/type and/or payload),
  fold into `Model` (or keep raw events), record `Cutoff = max(version)` (the `after`
  position).
- **{decide, Cmd}** — `decide(Model, Cmd)` → Events →
  `append_if_no_tag_matches(Filter, Cutoff, Events)`:
  - `ok` → fold Events into `Model`, bump `Cutoff`, reset idle timer, reply. *(no re-read)*
  - `{context_changed, _}` → re-read context, refresh `Model` + `Cutoff`, retry up to
    `retry_budget`. *(cache self-heals)*
- **timeout** — passivate/evict via lifespan (cold boundary leaves no footprint).

Reuse, not reinvention: partition sup, pg registry, lifespan, snapshot — all already
exist for the aggregate and are boundary-agnostic. The actor is ~one module.

### When to use which (guidance to ship in the docs)

| Boundary shape | Mode |
|---|---|
| keyed + hot + (near-)disjoint (seat, account, SKU) | **stateful actor** |
| keyed but cold / one-shot (email uniqueness at signup) | stateless |
| compound / no natural partition key (ad-hoc multi-tag) | stateless |
| per-entity lifecycle | it's an **aggregate**, not a decision |

---

## Compatibility & migration

- Part A: additive type variants + two adapter callbacks + runtime branches. Existing
  tag/type decisions unchanged. Requires reckon-gater ≥ 3.7, reckon-db ≥ 5.3 *only* for
  decisions that use payload filters.
- Part B: all new callbacks optional; absent `boundary_key/1` ⇒ today's stateless path
  verbatim. Opt-in per decision module.
- Version: minor evoq bump. `evoq_event_store` adapter gains two callbacks — coordinate a
  reckon_evoq release implementing them.

---

## Open questions

1. **Registry group collision.** Reuse `{decision, Module, Key}` in the same pg scope as
   `{aggregate, Id}` — fine (distinct tuples), or a separate scope for clarity?
2. **Cross-node hot boundaries.** Per-node actors are correct (store backstops) but a
   genuinely globally-contended boundary still pays cross-node retries. Optional future:
   a `global`/`via` singleton mode for the rare boundary that needs it — explicitly *not*
   v1 (it reintroduces the singleton failure modes the aggregate deliberately avoids).
3. **Decision-model snapshotting.** Worth caching a folded decision model to the store for
   very large/expensive contexts, or always rebuild on spawn? Default: rebuild (contexts
   for keyed boundaries are bounded). Reuse the aggregate snapshot hooks if needed.
4. **Should `boundary_key/1` validation cross-check the declared store indexes** at boot
   (warn if a payload filter references an undeclared index), reusing the gateway's
   discovery endpoint?

---

## Recommendation

Ship **Part A** first (small, unblocks payload-conditioned decisions, makes evoq the rare
event-sourcing framework whose consistency conditions can query opaque payload). Ship
**Part B** as the follow-up that turns hot keyed boundaries into first-class transient
aggregates — high leverage precisely because it reuses the aggregate's process machinery
wholesale and keeps the store's append condition as the one source of truth.
