# Changelog

All notable changes to evoq will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.24.1] - 2026-09-23

### Fixed — an aggregate over 1000 events could never accept another command

`evoq_aggregate` replayed a stream with ONE store read of 1000 events and
no loop. A longer stream loaded at version 999, and every command on it
failed `{wrong_expected_version, 999, N}`, forever, on both the load path
and the rebuild path. Found live on macula-realm (a 1173-event aggregate).
Replay now reads 1000-event pages until a short one, and refuses
(`{replay_not_advancing, ...}`) instead of looping if a store ignores the
start version.

### Fixed — resuming from a snapshot applied its last event twice

Replay after a snapshot at version V started at V (reads are inclusive), so
event V was applied again on top of the snapshot. It now starts at V + 1.
Only aggregates exporting `snapshot/1` and `from_snapshot/1` were affected.

### Known limit, not fixed here

Reads by event type and by tag (`evoq_decision_runtime`, projection
rebuild) return at most their batch size (1000), and reckon-db offers no
offset for them, so they cannot page from evoq. Tracked as an issue.

## [1.24.0] - 2026-09-23

### Fixed — a restart re-fired everything the node had already reacted to

`evoq_store_subscription` rescans the whole store on every boot, so
in-memory read models can rebuild, and routed every stored event to every
handler and process manager as if it were new. A process manager dispatched
its whole command history again and a side-effecting handler repeated every
side effect, on every restart. Measured live: 1174 re-publishes on one
macula-realm restart; the same in mcl-sentinel.

The persisted `$all` checkpoint (acked since 1.23.3) is now read at boot and
is the boundary. Events below it are **replay** and carry
`replaying => true` in their metadata, from catch-up and from backfill
alike. Events at or above it were appended while the node was down and are
delivered exactly as before. Live metadata is unchanged.

- **Process managers**: for replay, `handle/3` and `apply/2` still run, so
  an instance rebuilds exactly its state, but the commands `handle/3`
  returns are **not dispatched**.
- **Event handlers**: see *Added*. Undeclared handlers keep receiving
  replay, as before.
- **Projections**: unchanged.

### Added — `evoq_event_handler` optional callback `replay_policy() -> skip | deliver`

`skip` for a handler with side effects: it no longer sees replay. `deliver`
for a handler rebuilding in-memory state. Not declaring it delivers, as
before, and logs one warning per boot naming the handler the first time it
is handed replay (`what => evoq_handler_received_replay_without_policy`).
Any other return is an error.

**Consumers with side-effecting handlers should declare `skip`**: until
they do, they re-fire on restart exactly as on 1.23.x, and the warning names
them.

### Fixed — a handler's own messages never reached it

`evoq_event_handler`'s `handle_info/2` dropped every message, so a handler
that scheduled one to itself (a retry via `send_after`, as macula-realm's
delegation publisher does) never saw it and the retry silently never ran.

### Added — `evoq_event_handler` optional callback `handle_info/2`

Receives every other message the handler process gets, gen_server's shape:
`{noreply, NewState} | {stop, Reason, NewState}`. A handler without it that
is sent a message logs a warning naming itself and the message
(`what => evoq_handler_has_no_handle_info`).

### Fixed — a projection with a checkpoint store dropped the first event it was ever handed

A store holding no checkpoint yet (`load/1` returning `{error, not_found}`,
i.e. every projection's first boot) or a store without `load/1` loaded as
0, and since routed events are numbered from 0, event 0 read as already
covered and was skipped without a word. Both now load as -1, the value
`do_rebuild/1` already used for "nothing projected".

`evoq_projection:get_checkpoint/1` therefore returns **-1, not 0,** before
anything is projected when a checkpoint store is configured (it already
returned -1 without one), and is typed `integer()`.

### Build — project plugins pinned

`rebar3_hex` 7.2.0, `rebar3_ex_doc` 0.3.0, `rebar3_proper` 0.12.1,
`rebar3_lint` 6.0.0. `rebar3_hex` 7.3.0 ignores `HEX_API_KEY` and cannot
publish from CI; the pin is inside the tag, so an unpinned tag could not have
been rescued by a re-run.

### Tests — every unit test module runs

`eunit_tests` was a hand-kept module list, and two modules had never run in
CI (`evoq_aggregate_registry_tests`, `evoq_lineage_tests`). It is now
`{dir, "test/unit"}`. Two isolation bugs that the list had hidden are fixed.

### Known limits

- After a **crash**, up to 199 events delivered since the last ack arrive as
  new again. Exactly-once would need a checkpoint per handler.
- A node whose checkpoint was never moved (evoq before 1.23.3) sees its
  history as new once more, on its first boot with 1.24.0.
- An unreadable checkpoint is treated as "nothing is replay" (at-least-once)
  and logged.

## [1.23.4] - 2026-09-21

### Fixed — `event_type/0`'s declared type was narrower than this library's own runtime

`-callback event_type() -> atom().` is now `atom() | binary()`.

Nothing about behaviour changes. The spec was simply wrong about what evoq
accepts: `evoq_aggregate:resolve_event_type/1` has always had an `is_atom`
clause that converts to binary and an `is_binary` clause that passes through,
and every layer below it is binary-only — `{event_type, binary()}` in
`evoq_decision`, the `[by_event_type]` index read in
`evoq_decision_runtime`, `event_type :: binary()` in reckon_gater's shared
event record, and `is_binary` guards on reckon_db's index paths. The
atom-only spec was the single outlier in the whole stack.

The cost of it was borne by consumers: every Elixir event module returning a
string (the wire and event-store discriminator format the pipeline already
depends on) drew a dialyzer `callback_type_mismatch` it could not fix without
changing stored event data. macula-realm alone carried twelve
`.dialyzer_ignore.exs` entries for it, which between them masked the only
callback this behaviour actually checks.

Purely additive: Erlang implementations returning atoms, which is what the
hecate-sdk code generator emits, were correct before and are correct now.

## [1.23.3] - 2026-09-05

### Fixed — every event was delivered twice to every projection/PM, on every boot, since 2026-03-19

`evoq_subscriptions:ack/4` exists and is exported but was never called
anywhere in this module. Two consequences, both real in production
(confirmed live examples: hecate-tube's clip-publish/withdraw PMs,
hecate-victron's mesh-publish PM, hecate-sentinel's threat projection —
each fires an unconditional, undeduplicated side effect):

1. **Every fresh `$all` subscription always passed `start_from => 0`.**
   `subscribe_to_all/2` (now `/3`) hardcoded this regardless of what
   `catch_up_historical/1` (now `/2`, returning `{Seq, Offset}`) had
   already scanned moments earlier in the SAME boot. The persisted
   subscription's own catch-up (`reckon_db_subscriptions:maybe_start_catchup/2`)
   then redelivered the entire store a second time, immediately, every
   single first boot.
2. **Because `ack/4` was never called, the persisted checkpoint never
   advanced past that initial 0.** `reckon_db_subscriptions`' reconnect
   path (`reregister_subscriber/4`) resumes from the PERSISTED checkpoint
   on every restart — not from anything this process passes — so it
   replayed the entire store's history again on every restart too, not
   just the first boot. `route_event_with_seq/2`'s own `Metadata.version`
   (a monotonically-increasing per-delivery counter, overwritten
   specifically so $all subscribers get ordered checkpoints) means
   `evoq_projection`'s `EventVersion =< Checkpoint` guard and
   `evoq_event_handler`'s checkpoint tracking can NEVER recognize a
   duplicate delivery as one — a duplicate always gets a new, higher
   number. This was not a narrow race window; it was the normal, expected
   shape of every boot, and evoq's own advertised idempotency mechanism
   provided zero protection against it.

   Fixed both ends:
   - `catch_up_historical/2` now returns `{Seq, Offset}` -- Seq is how
     many events were actually routed (had a handler; unchanged
     semantics), Offset is how many were scanned, routed or not (the real
     global store position). `subscribe_to_all/3` is handed Offset0
     explicitly and passes it as `start_from`, closing the gap for a
     subscription's own very first ever create.
   - `handle_continue/2` now acks Offset0 to the persisted subscription
     BEFORE calling `subscribe_to_all/3` -- this is the one that actually
     closes every RESTART, not just the first boot: `start_from` only
     affects a subscription's initial creation
     (`reckon_db_subscriptions:store_and_setup/6`); on a reconnect,
     `reregister_subscriber/4` ignores it entirely and resumes from
     whatever checkpoint is already persisted. Acking here moves that
     checkpoint to Offset0 before the reconnect ever reads it, so its own
     catch-up (`maybe_start_catchup/2`) finds the store already fully
     covered. An adversarial review caught that the first cut of this fix
     only had the `start_from` half wired in -- both existing tests
     passed even with this exact call stubbed to a no-op, because a
     subscription's first-ever create doesn't need it. Confirmed empirically:
     without this line a restart still redelivered the gap since the last
     boot; with it, nothing.
   - `handle_info({events, Events}, State)` continues to ack afterward
     too, so a long-running instance's checkpoint doesn't go stale --
     coalesced to once every 200 events consumed rather than once per
     message, since acking is a synchronous, retrying, Raft-committing
     gateway call and doing it per live event would be a real throughput
     ceiling under sustained load that delivery never had before. A
     failed ack is logged and non-fatal.

   New tests boot a real `evoq_store_subscription` gen_server against a
   fake adapter modeling `reckon_db_subscriptions`' actual checkpoint
   semantics exactly (read from its source, not guessed: a fresh
   subscription honors the caller's `start_from`; a reconnect ignores it
   and resumes from the persisted checkpoint instead; acking a
   subscription that doesn't exist yet is a no-op, not a silent create --
   getting this last one wrong would let a test pass for the wrong
   reason, which is exactly what happened on the first pass before
   review). Three scenarios: a fresh boot over a 25-event store
   redelivers 0 events via the persisted subscription's own catch-up; a
   simulated restart (subscriber pid killed without a clean unsubscribe,
   store grown by 10 events while "down") redelivers 0 (not the original
   bug's whole-store replay, and not the 10-event partial fix an earlier
   version of this change stopped at); and acking directly against the
   real `evoq_subscriptions` API confirms an existing checkpoint moves
   and a missing one no-ops.

   Note what this fix deliberately does NOT change: `catch_up_historical/2`
   (Phase 1) still rescans the whole store fresh on every single boot, by
   original design, independent of any checkpoint -- a side-effecting
   handler still fires for the entire history once per restart, same as
   before this fix. What's fixed is the SEPARATE, redundant redelivery
   the persisted `$all` subscription's own catch-up used to add on top of
   that, which is the part that was silently doubling everything.

## [1.23.2] - 2026-09-05

### Fixed — a slow catch-up replay blocked this process's own start_link, not just the caller

`evoq_store_subscription:init/1` ran the full historical catch-up replay
(`catch_up_historical/1`) synchronously before returning, which meant
`gen_server:start_link` — and therefore this process's supervisor's own
start_link — stayed blocked for the whole replay. Against a store with real
accumulated volume this is not fast (reckon_db 5.11.1's cache alone measured
~110-130ms/page against a real ~87k-event evidence store, and the full
scan-and-sort for the first page was ~1.5s even on capable hardware — see
reckon_db 5.11.3's changelog for the read-side fix). On weaker or loaded
hardware that is long enough to plausibly trip an external liveness
expectation (a container healthcheck, a supervisor timeout) mid-replay;
killing the node there restarts catch-up from offset 0 with nothing carried
over — a crash-restart loop that never gets past the first page, matching
exactly what was observed in production (hecate-sentinel, stopped
2026-09-01 after this pattern pushed CPU past 300%+ and kept climbing).

Moved catch-up into `handle_continue/2` (`{continue, catch_up}` returned
from `init/1`): this process now reports "started" to its supervisor
immediately, and the replay runs right after — still before this process
handles its first real message, so event ordering is unchanged — but
without blocking `start_link` itself. New test asserts `init/1` returns in
under 100ms against a store id that would hang or error if init/1 still
touched it directly, proving catch-up genuinely moved out.

**A second bug this surfaced (caught by adversarial review before release,
not by the fix's own author):** making catch-up asynchronous means a
handler can now register for a type WHILE catch-up is running, which was
never previously possible — `init/1` used to block the whole node, so no
sibling application could register a handler mid-replay. `catch_up_loop/4`
routed by calling `evoq_event_type_registry:get_handlers/1` live, at
delivery time; a type gaining its first handler mid-burst would then get
routed by catch-up for every event scanned AFTER the registration landed,
*and* delivered again in full when the queued `{new_event_type, EventType}`
notification ran `backfill_event_type/3` right after catch-up finished —
double delivery for exactly the events that happened to be scanned after
the race. Fixed by gating catch-up's routing on `known_types`, the type
snapshot `register_listener/1` already returned in `init/1` (previously
discarded) — a type absent from that snapshot is now *always* skipped by
catch-up, unconditionally, deferring its entire history to the backfill
sweep exactly as if the handler had registered after catch-up finished
outright (one delivery, not a mix of two paths). New tests cover
`filter_by_type_set/2` directly, including the exact "type present at
scan time, absent from the original snapshot" case.

Also: `catch_up_loop/4` now logs elapsed time per page, not just event
counts (`[evoq] Catch-up ~s: routed ~b events (seq ~b -> ~b) in ~.1fms`) —
the gap between reckon_db 5.11.1's synthetic 10k-event benchmark and its
real ~87k-event behavior was only found by rebuilding a from-scratch repro
against real data; per-page timing in the normal logs would have made
that unnecessary.

## [1.23.1] - 2026-08-25

### Fixed — a handler registering after catch-up never saw events already appended

`evoq_store_subscription` replays a store's full history exactly once, at
subscription startup (the "catch-up" phase), routing each event to whichever
handlers are registered for its type *at that moment*. A handler for a type
that registers **after** catch-up already ran — the normal shape for any
multi-application/umbrella architecture where the application owning the
store's subscription boots before the applications registering handlers for
it, not an edge case — never received the history appended before it
subscribed. The module already listened for `{new_event_type, EventType}`
(fired once, when a type gets its first-ever handler) but only logged
"already covered by `$all`" and did nothing: true for events appended *after*
the subscription started, false for anything appended before a late
handler's type had *any* handler at all.

Confirmed live in `hecate-whiteboard` (a real 3-app CMD/PRJ/QRY umbrella)
2026-08-25: a container restart with 13 real historical events logged
`handlers=0` for every one during catch-up, then the exact "already covered"
message once the PRJ app's projection handlers registered ~0.8s later — the
read model came back completely empty on every restart from then on, even
though the underlying event store was untouched.

Fix: on `{new_event_type, EventType}`, `evoq_store_subscription` now
backfills history for that one type internally (reusing
`route_events_with_seq/2` on the existing running `seq` counter so no
version collides with anything already delivered) instead of a no-op log
line. Filtered to the newly-registered type only, so already-covered
handlers for other types see no redundant delivery.

No public API changes. `filter_by_type/2` is exported for unit testing only,
same convention `evoq_event_to_routable/1`/`route_event/1`/
`route_events_with_seq/2` already use in this module.

## [1.23.0] - 2026-06-25

### Added — stateful Decision/Context actor (CCC Part B)

Opt-in per-node `gen_server` mode for `evoq_decision`, keyed on a decision-declared
boundary key. For a keyed, hot boundary (one seat, one account, one SKU) it
serialises commands at one process and caches the folded decision model, so the
store's append condition passes first try instead of N−1 `context_changed`
retries. It is a per-node cache + serialiser, **never** the correctness
authority — reckon-db's `append_if_no_tag_matches/4` stays the sole source of
truth; on `context_changed` the actor invalidates, re-reads, and retries.

- `evoq_decision` gains three **optional** callbacks: `boundary_key/1` (the
  opt-in switch; `undefined`/absent ⇒ today's stateless path verbatim),
  `init_decision_model/0` + `apply_context_event/2` (optional folded model;
  when both present, `decide/2` receives the folded model instead of the raw
  context-events list).
- New modules: `evoq_decision_actor`, `evoq_decision_registry` (own
  `evoq_decision_pg` scope, group `{decision, Module, Key}`, node-local lookup),
  `evoq_decision_partition_sup`, `evoq_decisions_sup` (4 partitions by
  `phash2({Module, Key})`). Wired under `evoq_sup`. A **parallel** tree — no
  aggregate module changed (see `proposals/SPIKE_EVOQ_DECISION_ACTOR.md`, Path 1).
- `evoq_decision_runtime:dispatch/3` is now a facade: `boundary_key` present ⇒
  route to the actor; absent ⇒ stateless loop. Shared `load_context/2` keeps one
  context-read + cutoff rule across both paths.
- Lifespan/TTL reuses `evoq_aggregate_lifespan` as-is; idle actors passivate
  (v1: stop + rebuild on next spawn). Decision-model snapshotting (proposal OQ3)
  is left as a documented extension point in `evoq_decision_actor`.

Backwards-compatible: all new callbacks optional; no existing decision changes
behaviour. Minor bump (no aggregate API broke — 2.0 not required).

## [1.22.0] - 2026-06-25

### Added — CCC payload conditions in `evoq_decision:context_filter()` (Part A)

DCB decisions can now scope their consistency context on **opaque event-data
fields**, not just tags/types. This is the CCC (Consistency Context Condition)
dimension reckon-db exposes via payload indexes, lifted into evoq's Decision
behaviour. Tag/type-only decisions are unchanged.

- `evoq_decision:context_filter()` gains two leaves:
  - `{payload_match, Key :: binary(), Value :: binary()}` — payload field equals.
  - `{payload_hash_match, Keys :: [binary()], Values :: [binary()]}` — composite.
- `evoq_event_store`: new `ccc_read_by_payload/4` and `ccc_read_by_payload_hash/4`
  reads, plus `payload_indexes/1` / `payload_hash_indexes/1` introspection
  (the latter degrade to `{error, introspection_unavailable}` on adapters that
  predate them).
- `evoq_adapter`: four new **optional** callbacks for the above.
- `evoq_decision_runtime`: payload read branches; `match_filter/2` gains
  `payload_match` / `payload_hash_match` clauses that read flattened data fields.

### Fixed — compound-filter (`or_`) superset bug

The runtime now reads **every leaf of a compound filter fully** via its own
index, unions the results, and refines client-side — replacing the
collect-tags-then-single-union-read path. `{or_, [...]}` mixing tag,
`event_type`, and payload leaves is now correct: no branch is inferred from a
sibling. `match_filter/2` recurses over the event map (not its tag list) inside
`and_`/`or_`, so `event_type`/payload leaves nested in a compound evaluate
correctly.

### Graceful degradation (required by the proposal)

A decision using a payload leaf against a store that does not declare the
matching index fails **loudly and early** with
`{error, {payload_index_unavailable, Filter}}` — it never silently returns an
empty context and lets a bad decision through. The decision runtime also no
longer crashes on a context read error; it propagates it to the caller.

**Requires reckon-gater >= 3.7 / reckon-db >= 5.3** for the payload indexes,
*only* for decisions that use payload leaves. (gater 3.7 adds the
`get_payload_indexes/1` / `get_payload_hash_indexes/1` introspection the
runtime needs to fail loud; the `ccc_read_by_payload*` reads landed in 3.6.)
Pair with a `reckon_evoq` release implementing the four adapter callbacks
(delegating to `reckon_gater_api:ccc_read_by_payload/4`,
`ccc_read_by_payload_hash/4`, `get_payload_indexes/1`,
`get_payload_hash_indexes/1`) — shipped in reckon-evoq 2.7.0.

## [1.21.0] - 2026-06-22

### Added — `{event_type, binary()}` in `evoq_decision:context_filter()`

DCB decisions can now scope their consistency context by event type, mirroring
the `{event_type, binary()}` leaf added to `reckon_gater_types:tag_filter()` in
reckon-gater 3.4.0 / reckon-db 5.2.0.

- `evoq_decision:context_filter()` gains the `{event_type, binary()}` variant.
- `evoq_decision_runtime:read_context/2`: new top-level clause hits the
  `[by_event_type]` Khepri index directly via
  `evoq_event_store:read_events_by_types/3`.
- Compound filters (`and_`/`or_`) that reference `{event_type, T}` are now
  handled by unioning tag-index and event-type-index reads before client-side
  refinement, so `{and_, [{event_type, T}, {any_of, Tags}]}` is fully correct.
- `match_filter/2` (public testing API): new `{event_type, T}` clause reads
  `event_type` from the event map rather than the tag list.
- `collect_event_types/1` added to the internal test-API export.

**Requires reckon-db 5.2.0+** for the `[by_event_type]` index. Events written
before 5.2.0 have no index entries and will not match `{event_type, T}` filters
(same caveat as the backend guide documents).

**v1 compound-filter limitation:** `{or_, [{event_type, T}, {any_of, Tags}]}`
may miss events that match only the `{event_type}` branch but carry none of the
tags referenced by sibling branches. See `context_filter()` type docs.

## [1.20.0] - 2026-06-08

### Added — `evoq_lineage`: first-class correlation/causation API

The Enterprise Integration Patterns correlation/causation identifiers are now
a named, intent-revealing capability rather than raw metadata-map digging.

- New `evoq_lineage` module:
  - accessors `causation_id/1`, `correlation_id/1`, `conversation_id/1` over an
    event's metadata map (tolerant of atom keys in-process and binary keys after
    JSON round-trip);
  - canonical key binaries `causation_key/0` etc. (single source of truth for
    the names, matching reckon_shared.proto);
  - lineage queries `get_effects/2` (events directly caused by a message),
    `get_correlated/2` (the conversation), `get_conversation/2` — thin wrappers
    over `read_by_metadata` with the blessed keys.
- `evoq_event_store:read_by_metadata/3` delegates to the adapter (paired with
  reckon-evoq 2.4.0 / reckon_gater 3.2.0 / reckon-db 5.0.0).
- Reserved lineage key macros in `evoq.hrl` (`?EVOQ_META_CAUSATION_ID` etc.);
  `evoq_aggregate` now propagates via these instead of bare literals.

Design stance: evoq owns the intent-revealing API and auto-propagation; the
store stays generic with only `read_by_metadata` (no server-side
get_effects/graph verb). Multi-hop chain/graph assembly is composed by the
application over `get_effects` / `get_correlated`, never in the store.

## [1.19.0] - 2026-05-27

### Added — compound filters in `evoq_decision`

The `evoq_decision:context_filter()` type now includes the
recursive `and_` and `or_` cases, matching the backend's
`reckon_gater_types:tag_filter()` exactly:

```erlang
-type context_filter() ::
      {any_of, [binary()]}
    | {all_of, [binary()]}
    | {and_, [context_filter()]}
    | {or_,  [context_filter()]}.
```

`evoq_decision_runtime:read_context/2` now plumbs compound filters
through the read path: walks the filter tree, collects the union of
referenced tags, hits `read_by_tags` once with the broad set, then
filters client-side using per-event semantics. Empty `{and_, []}` /
`{or_, []}` filters short-circuit to an empty context (no read).

This closes the v1 limitation noted in the 1.18.0 release. The
backend's conditional-append check already supported compound filters
(in reckon-db 3.1.0); now the runtime can express the same shapes.

5 new eunit tests cover or-of-flats, and-of-flats, nested compound
(`or_(any_of, all_of)`), and empty-compound short-circuit. All 90
existing eunit tests still pass.

## [1.18.0] - 2026-05-27

### Added — `evoq_decision` behaviour + runtime (DCB)

A new write-side construct that sits alongside `evoq_aggregate`.
Where an aggregate locks on its own stream's version (stream-per-thing
optimistic concurrency), a Decision locks on the absence of new events
matching a tag-filter context query (Dynamic Consistency Boundary).

Decisions are for cross-cutting checks that don't fit the per-entity
Dossier shape — uniqueness, allocation against shared resources,
idempotency keys, rate limits.

**Behaviour module** (`evoq_decision`):

```erlang
-callback context(Command :: map()) -> context_filter().
-callback decide(ContextEvents :: [map()], Command :: map()) ->
      {ok, [Event :: map()]}
    | {error, Reason :: term()}.

%% Optional
-callback retry_budget() -> non_neg_integer().  %% default 3
```

`context_filter()` v1 supports `{any_of, [Tag]}` and `{all_of, [Tag]}`
(flat predicates only).

**Runtime module** (`evoq_decision_runtime`):

```erlang
evoq_decision_runtime:dispatch(MyDecisionMod, StoreId, Command).
```

The runtime: calls `context/1`, reads matching DCB-stream events,
computes the seq cutoff (max version seen, or -1), calls `decide/2`,
appends conditionally via the configured adapter, retries on
`{error, {context_changed, _}}` with bounded exponential backoff +
jitter. Default retry budget 3.

**evoq_event_store** gains two wrapper functions delegating to the
adapter:

- `evoq_event_store:read_by_tags/4`
- `evoq_event_store:append_if_no_tag_matches/4`

Adapters must implement these to support `evoq_decision`. The
`reckon_evoq` adapter has done so since 2.2.0.

### v1 limitations

- **Flat filters only.** Compound `and_` / `or_` filters are supported
  by the reckon-db backend's conditional-append check, but the
  runtime's read path doesn't yet translate them. Use multiple
  decisions or flat filters at the evoq layer.
- **DCB-stream only.** The runtime considers events from the
  `<<"_dcb">>` pseudo-stream only when computing the cutoff. Mixed-
  mode use cases (aggregate streams + DCB sharing tags) are not
  supported by `evoq_decision` — use `evoq_aggregate` for
  per-aggregate consistency, `evoq_decision` for pure cross-cutting.
- **No options API.** Retry budget can be set via callback only;
  there's no `dispatch/4` taking a per-call options map yet.

### Notes

`evoq_aggregate` is unchanged. Apps that don't use DCB are unaffected.
This release adds two new modules and two new functions in
`evoq_event_store`. Backward-compatible.

Publish ordering: reckon-gater 2.3.0 -> reckon-db 3.1.0 ->
reckon-evoq 2.2.0 -> evoq 1.18.0. For local dev, the local
reckon_gater is linked via `_checkouts/`.

## [1.15.0] - 2026-05-15

### Added — Integrity-violation classification and chain-hash propagation

Layer 6 of the cross-package tamper-resistance work in
reckon-db/plans/PLAN_TAMPER_RESISTANCE.md. Pure additions plus
one non-breaking error-handling fix; no API removed, no caller
broken.

#### Schema

- `#evoq_event{}` gains `prev_event_hash :: binary() | undefined`.
  Carried verbatim from reckon-gater's `#event{}` through the
  reckon-evoq adapter so projections and process managers can
  keylessly verify chain continuity as defense-in-depth.
- The `mac` and `signature` fields on the storage-side record
  are intentionally NOT propagated into evoq. They belong to
  the storage layer and require the per-store HMAC / public key
  that the framework does not (and must not) hold.
- `evoq_event_store:event_to_map/1` includes `prev_event_hash`
  in the produced map.

#### Error classification

- New `evoq_aggregate:is_integrity_violation/1` recognises the
  `{error, {integrity_violation, _}}` class shipped by reckon-db
  2.1.0. Distinct from `wrong_expected_version`: must NOT enter
  the rebuild-and-retry loop.
- Post-append error path now classifies and handles integrity
  violations explicitly — surface verbatim, emit telemetry
  `[evoq, aggregate, integrity, violation]`, no retry.
- `rebuild_and_reply_conflict/4` distinguishes integrity from
  other rebuild failures. Previous behaviour normalised any
  rebuild error to `wrong_expected_version`, which would have
  caused the dispatcher to spin against corrupted state until
  the retry cap. Integrity errors now surface immediately.

#### Compatibility

- Requires reckon-gater >= 2.1.0 only if you want chain hashes
  to flow through to the evoq layer. evoq 1.15 builds and runs
  fine against reckon-gater 2.0.x — the new record field
  defaults to `undefined` everywhere.
- Existing callers constructing `#evoq_event{}` without the new
  field continue to compile and run.

#### Tests

14 new eunit tests in `evoq_aggregate_integrity_tests`:
classifier shape recognition (storage / replay / snapshot
violations with various context maps), negative cases that
must NOT over-match (wrong-version errors, stream-not-found,
bare violations, atom-collision cases, success tuples,
arbitrary terms), and schema sanity (record has the field,
defaults to undefined, survives the record→map boundary).

Full eunit: 75 tests pass (61 existing + 14 new). Zero regression.

### Changed

- `src/evoq.app.src`: `{links, [{"GitHub", ...}]}` updated to
  `{"Codeberg", ...}` to match canonical hosting.

## [1.14.4] - 2026-04-24

### Fixed

- `evoq_aggregate` now recognises every shape of the
  `wrong_expected_version` error the backend can produce —
  `{error, wrong_expected_version}`,
  `{error, {wrong_expected_version, Actual}}`, and the current
  reckon-db form `{error, {wrong_expected_version, Expected, Actual}}`.
  The old handle_call matched only the plain-atom form, so the real
  3-tuple returned by reckon-db fell through to the generic error
  branch and the rebuild/retry machinery was dead code: commands
  like `confirm_realm_membership` surfaced the raw conflict up to
  the caller instead of triggering a rebuild + dispatcher retry.

  The classifier is factored into `is_wrong_version_error/1` and
  wired through a single reply helper so adding a new shape in the
  future is a one-line change. Regression test in
  `test/unit/evoq_aggregate_version_conflict_tests.erl`.

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

