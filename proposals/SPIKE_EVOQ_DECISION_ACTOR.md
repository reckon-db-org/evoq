# SPIKE: Part B — does the aggregate machinery actually reuse?

**Status:** Spike complete, 2026-06-25
**Question it answers:** the proposal claims the stateful Decision/Context actor
runs "under the **existing** `evoq_aggregate_partition_sup`, registered in the
**existing** pg registry … the actor is ~one module." Is that literally true?
And does reuse force breaking changes (→ evoq 2.0) or stay additive (→ 1.23)?

## Finding: the claim is half true

| Machinery | Reusable as-is? | Why |
| --- | --- | --- |
| `evoq_aggregate_lifespan` (behaviour) | **Yes, literally** | Pure callbacks (`after_event/command/error`, `on_timeout/passivate/activate`). Entity-agnostic. A decision actor implements it unchanged. |
| `evoq_aggregate_lifespan_default` | **Yes** | Usable defaults (TTL, hibernate). |
| pg scope `evoq_pg` | **Yes, as a mechanism** | Just a process-group namespace. A decision actor can `pg:join(evoq_pg, {decision, Mod, Key}, self())`. Reuse is the *scope*, not a module. |
| snapshot path (lifespan `on_passivate/on_activate` + adapter `save/read`) | **Yes** | Already exists end-to-end. See OQ3 below. |
| `evoq_aggregate_registry` | **No** | Every function hardcodes `{aggregate, AggregateId}` in its pg calls; `lookup/get_or_start/register` are bound to aggregate identity. The node-local `find_alive_local/1` logic is *exactly* what a decision actor wants, but it's entangled with the aggregate tuple. |
| `evoq_aggregate_partition_sup` | **No** | Child spec is hardwired `{evoq_aggregate, start_link, []}`. Cannot start `evoq_decision_actor` without a different spec. |
| `evoq_aggregates_sup` | **No** | 4 partition sups all wired to `evoq_aggregate`; `partition_for/1`, `partition_sup_name/1` are aggregate-specific. |

So: **lifespan + pg-scope + snapshot are literally reusable. The sup tree and the
registry are hardwired to the aggregate entity-kind and are not.** "The actor is
~one module" undersells it — you also need a child spec, sup wiring, and a
registry helper for the `{decision, Mod, Key}` identity.

## Version verdict: 1.23, not 2.0 — either path

Neither path below changes an exported aggregate signature, so **B is a minor
bump**. The only thing that would force 2.0 is breaking an aggregate export; both
paths avoid it.

## Path 1 — parallel decision sup tree (recommended for v1)

New modules, **none touching aggregate code → zero risk to aggregates**:

- `evoq_decision_actor` — the gen_server. **init:** run `context/1` once via the
  adapter, fold into `Model` (or keep raw events), record `Cutoff = max(version)`.
  **`{decide, Cmd}`:** `decide(Model, Cmd)` → `append_if_no_tag_matches(Filter,
  Cutoff, Events)` → on `ok` fold Events into `Model` + bump `Cutoff` (no re-read);
  on `context_changed` re-read context, refresh `Model`+`Cutoff`, retry to
  `retry_budget`. **timeout:** passivate via lifespan. Uses
  `evoq_aggregate_lifespan` unchanged.
- `evoq_decision_partition_sup` — `simple_one_for_one`, child
  `{evoq_decision_actor, start_link, []}`.
- `evoq_decisions_sup` — N partition sups + the decision registry; distribute by
  `phash2({Mod, Key}, N)`.
- `evoq_decision_registry` — `get_or_start/lookup` over pg group
  `{decision, Mod, Key}` (separate tuple/scope per proposal OQ1 = "separate").
  Mechanically the aggregate registry with the tuple swapped + the same
  node-local `find_alive_local/1`.

Cost: ~4 small modules, mostly mechanical, reusing lifespan + pg + snapshot.
The stateless `evoq_decision_runtime` stays the default; `evoq_decision`'s
optional `boundary_key/1` is the opt-in switch (absent ⇒ today's path verbatim).

## Path 2 — generalize the shared infra (defer)

Make `evoq_aggregate_partition_sup` take the worker module as an arg, and make
`evoq_aggregates_sup` + `evoq_aggregate_registry` entity-kind-generic (`{Kind,
Id}` tuple, `start_child([Mod, Id, StoreId])`), with the aggregate paths
delegating (Kind=aggregate). Can be done **additively** (keep existing exports,
add generic ones) → still non-breaking → 1.23. But it touches load-bearing
aggregate modules, so it needs the full aggregate suite green to de-risk.

**Defer it.** Payoff is real (process managers — `evoq_pm_sup` /
`evoq_pm_instance_sup` — already duplicate this pattern, so a future "entity
process" generalization could fold aggregate + decision + PM into one sup/registry
substrate), but that is a standalone refactor worth its own session, *not* a
prerequisite for shipping B. Build B on Path 1; harvest into Path 2 later if a
third entity-kind justifies the DRY.

## OQ3 (snapshotting) — already solved by reuse

`evoq_aggregate_lifespan` already exposes `on_passivate/1` (produce snapshot) and
`on_activate/2` (rebuild from snapshot), and the adapter already has snapshot
`save/read`. So decision-model snapshotting is **a lifespan-impl choice in
`evoq_decision_actor`, not new infrastructure**. v1 default: rebuild-on-spawn;
expose the hooks so a large-context boundary (the CCC case where event sets dwarf
classic aggregate streams) can opt into snapshotting with no new code. This is
the cheap answer to "VERY INTERESTING IDEA."

## OQ4 (boot-time index cross-check) — folds into Part A's introspection

`evoq_event_store:payload_indexes/1` (already shipped in 1.22) is the discovery
endpoint. A `boundary_key`-bearing decision can validate its payload filters
against the declared indexes at registration/boot and warn on a miss, reusing the
exact call the runtime already uses to fail loud at read time.

## Recommendation

Build **B v1 on Path 1** (isolated, non-breaking, ~4 small modules, 1.23). Keep
snapshot hooks exposed but defaulted off. Defer Path 2 generalization. No 2.0.
