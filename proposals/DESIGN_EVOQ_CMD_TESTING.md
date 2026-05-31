# DESIGN: evoq CMD-level Domain Testing Framework

**Status:** Draft (2026-05-31) — awaiting approval. No code until approved.
**Repo:** `reckon-db-org/evoq` (currently v1.19.0).
**Motivated by:** a real hecate-parksim/ClankerCab incident where every layer
returned `ok` while zero domain events persisted.

---

## 1. Motivation — the incident this would have caught

On 2026-05-31 the hecate-parksim robotaxi fleet ran live on beam00-03: the
brain ticked, telemetry flowed, the map moved, and `dispatch` returned `ok`
everywhere. Yet the SQLite read model was **empty** — `trips`, `revenue`,
facility occupancy all 0. Three silent failures hid behind one another:

1. **Stream-id rejection (the source).** The vehicle aggregate dispatched with
   the human id `<<"leuven-taxi-1">>` as the evoq `AggregateId` == reckon-db
   stream id. reckon-db requires stream ids to match
   `^[a-z]{1,32}-[a-f0-9]{32}$` (`reckon_gater_stream_id`), so EVERY dispatch
   returned `{error, {invalid_stream_id, malformed_user_id, _}}`.
2. **Swallowed dispatch.** The caller did `_ = catch Mod:dispatch(Payload)`, so
   the error vanished. No crash, no log.
3. **Empty projection.** With no events persisted, the projection had nothing
   to fold; the read model stayed empty; the mesh summary fact reported 0s.

**Every existing test passed.** The lesson the corpus already names —
*"ok without observability is a lie"* (ANTIPATTERNS_MESH_PUBSUB) — applied at
the CMD layer. This framework makes "prove the event landed" the default unit
of domain testing, not "dispatch returned ok."

---

## 2. What exists today (do not duplicate)

| Asset | What it does | Gap |
|-------|-------------|-----|
| `evoq_test_assertions` | `assert_command_succeeds/fails[_with]`, `assert_event[s]_produced`, `assert_aggregate_state`, `assert_read_model_contains/empty`, telemetry asserts. Dispatches via `evoq_router:dispatch` and asserts the RETURNED `{ok,_,Events}`. | Asserts the dispatch *return value*, not a stream read back from the store. No `given/when/then` matrix sugar. No stream-id validity check. |
| `test/integration/evoq_dispatch_SUITE.erl` (+ `evoq_pm_SUITE`, `evoq_projection_SUITE`, `evoq_error_handling_SUITE`, `evoq_event_handler_SUITE`) | common_test suites: `init_per_suite` starts `evoq` (+ reckon-db store), dispatch, read back via `evoq_event_store:read_events/4`. | Exercise evoq's OWN internal test aggregate; not reusable by a domain app; not parameterised by a domain aggregate + its stream-id scheme. |
| `reckon_gater_stream_id:validate/1` | the regex that rejected the id on 2026-05-31 | Never invoked by any evoq test path, so malformed ids only fail in prod. |

The framework **reuses** `evoq_test_assertions` for the pure layer and
**generalises** the `evoq_dispatch_SUITE` store-fixture idiom into a
domain-facing harness. It replaces neither.

---

## 3. Two layers

### Layer A — pure aggregate spec (fast, the bulk)

`given(PriorEvents) → when(Command) → expect_events([...]) | expect_error(R)`.
Runs `Mod:init/1`, folds `PriorEvents` via `Mod:apply/2`, then calls
`Mod:execute/2`, asserting on the result. No store, no processes.

```erlang
%% (arrows are illustrative — Erlang has no |>; real API in §5)
spec(vehicle_aggregate)
  | given_events([commissioned(<<"leuven-taxi-1">>)])
  | when_command(dispatch_vehicle, #{vehicle_id => <<"leuven-taxi-1">>, ...})
  | expect_event(<<"vehicle_dispatched">>).

spec(vehicle_aggregate)
  | given_events([])                          %% pristine
  | when_command(pick_up_passenger, #{...})
  | expect_error(vehicle_not_dispatched).     %% precondition holds
```

### Layer B — integration dispatch spec (proves persistence)

The layer that would have caught the incident. Dispatches a real command
sequence through `evoq_dispatcher:dispatch/2` against a real reckon-db store,
then **reads the stream back and asserts the event types that landed** — and
that the projection folded them.

```erlang
evoq_cmd_case:with_store(fun(StoreId) ->
    Seq = [ {commission_vehicle, #{vehicle_id => Vid, ...}},
            {dispatch_vehicle,   #{vehicle_id => Vid, ...}},
            {pick_up_passenger,  #{vehicle_id => Vid, ...}},
            {drop_off_passenger, #{vehicle_id => Vid, ...}} ],
    ok = evoq_cmd_case:dispatch_all(vehicle_aggregate, Vid, Seq, StoreId),
    %% PROVE the events landed — not that dispatch returned ok:
    evoq_cmd_case:assert_stream(StoreId, Vid,
        [<<"vehicle_commissioned">>, <<"vehicle_dispatched">>,
         <<"passenger_picked_up">>, <<"passenger_dropped_off">>])
end).
```

`assert_stream` fails loudly if any expected event is absent — exactly the
assertion missing on 2026-05-31, where `[commissioned, dispatched]` landed but
`picked_up`/`dropped_off` never did.

Optional projection chain:

```erlang
    evoq_cmd_case:assert_projection(StoreId, vehicle_event_to_read_model,
        fun() -> project_fleet_store:overview() end,
        fun(Ov) -> ?assertEqual(1, maps:get(trips, Ov)) end)
```

---

## 4. The non-negotiable assertion: prove the event landed

> A passing CMD test MUST read the persisted stream back and compare event
> types. `dispatch` returning `{ok, _, _}` is necessary but NOT sufficient.

`evoq_cmd_case:dispatch_all/4`:
- asserts each `dispatch/2` returns `{ok, _Version, _Events}` (never silently
  tolerates `{error, _}` — the swallow that hid bug #2 is impossible here), and
- after the sequence reads the stream back via `evoq_event_store:read_events(
  Store, AggId, 0, N)` (the call `evoq_dispatch_SUITE` already uses) and
  compares event types.

This turns all three 2026-05-31 failures into red tests at the source.

---

## 5. API sketch (Erlang)

Two new test-support modules in `src/` (or `test/support/`) + one header. The
builder threads an opaque spec record (no `|>` in Erlang).

```erlang
%% Pure layer — builder over execute/2 + apply/2 (+ evoq_test_assertions).
-module(evoq_aggregate_spec).
-export([new/1, given_events/2, when_command/3,
         expect_event/2, expect_events/2, expect_error/2]).
%% new(AggMod) -> spec()
%% given_events(spec(), [EventMap]) -> spec()   %% folded via AggMod:apply/2
%% when_command(spec(), CmdType :: atom(), Payload :: map()) -> spec()
%% expect_event(spec(), EventType :: binary()) -> ok   %% runs execute/2 + asserts
%% expect_error(spec(), Reason :: term())      -> ok

%% Integration layer — real reckon-db store fixture + dispatch + readback.
-module(evoq_cmd_case).
-export([with_store/1, with_store/2,
         dispatch_all/4, assert_stream/3, assert_projection/4,
         assert_valid_stream_id/1]).
%% with_store(fun((StoreId) -> any())) -> any()
%%   starts a unique tmp single-mode reckon-db store (idiom from
%%   evoq_dispatch_SUITE init_per_suite; SKIPS if reckon-db unavailable),
%%   runs Fun, tears it down (removes the tmp dir).
%% dispatch_all(AggMod, AggId, [{CmdType, Payload}], StoreId) -> ok
%%   builds evoq_command:new/5 per step, dispatches, asserts each {ok,_,_};
%%   also runs assert_valid_stream_id(AggId) up front.
%% assert_stream(StoreId, AggId, [ExpectedEventType]) -> ok
%%   evoq_event_store:read_events(StoreId, AggId, 0, N); compares the
%%   event_type list (order-sensitive).
%% assert_projection(StoreId, ProjMod, ReadFun, AssertFun) -> ok
%%   starts ProjMod against the store, lets catch-up run, asserts ReadFun().
%% assert_valid_stream_id(AggId) -> ok
%%   reckon_gater_stream_id:validate(AggId) =:= ok, else fail naming the regex.
```

---

## 6. Stream-id validity as a first-class check

`assert_valid_stream_id/1` (and the automatic check inside `dispatch_all`) runs
`reckon_gater_stream_id:validate/1` on the AggregateId. A domain author writing
`assert_valid_stream_id(vehicle_aggregate:stream_id(<<"leuven-taxi-1">>))` gets
green; writing it for the raw `<<"leuven-taxi-1">>` gets an instant red naming
the regex. Cheapest possible guard for the exact bug class — no store needed.

---

## 7. First consumer: guide_vehicle_lifecycle (retrofit table)

The 10 vehicle commands are the framework's proof-of-use. Pure-layer matrix:

| Command | Prior phase (given) | Expect |
|---------|---------------------|--------|
| `commission_vehicle` | pristine | event `vehicle_commissioned` |
| `commission_vehicle` | commissioned | error `vehicle_already_commissioned` |
| `dispatch_vehicle` | cruising/commissioned | event `vehicle_dispatched` |
| `pick_up_passenger` | dispatched | event `passenger_picked_up` |
| `pick_up_passenger` | pristine | error `vehicle_not_dispatched` |
| `drop_off_passenger` | on_trip | event `passenger_dropped_off` |
| `drop_off_passenger` | dispatched | error (not on trip) |
| `return_vehicle` | cruising | event `vehicle_returning` |
| `dock_at_facility` | returning | event `vehicle_docked_at_facility` |
| `service_vehicle` | docked | event `vehicle_serviced` |
| `release_vehicle` | servicing | event `vehicle_released` |
| `deplete_battery` | on_trip | event `battery_depleted` |

Integration-layer: one happy-path sequence
(`commission→dispatch→pickup→dropoff`) asserting all four events persist + the
read model shows `trips = 1`, plus `assert_valid_stream_id` over
`vehicle_aggregate:stream_id/1`. These three would each have failed on
2026-05-31.

---

## 8. Non-goals

- Not a mocking framework. Layer B uses a real reckon-db store (single mode,
  tmp dir) — that is the point.
- Not a mesh/integration-fact tester. Stops at the local event store +
  projection.
- Not a property-based generator (`test/property/` stays separate; could feed
  it later).
- Does not change `evoq_aggregate`/`evoq_dispatcher` runtime behaviour — test
  support only.

---

## 9. Rollout

1. Land `evoq_aggregate_spec` + `evoq_cmd_case` + header with evoq's own
   self-tests (reuse the existing internal test aggregate).
2. Minor version bump (1.19 → 1.20); guide `guides/cmd_testing.md`.
3. First external consumer: hecate-parksim `guide_vehicle_lifecycle` §7 matrix
   — proves the framework + permanently locks the stream-id regression.
4. Backfill other CMD apps opportunistically.

---

## 10. Open questions for the reviewer

- **Module split** — `evoq_aggregate_spec` (pure) + `evoq_cmd_case`
  (integration), or one `evoq_cmd_test`? Leaning two: the pure layer must stay
  store-free and fast.
- **Where they live** — `src/` (shipped, usable by consumers' test suites) vs
  `test/support/` (not shipped). Consumers need them at test time, so `src/`
  with a thin always-available API, mirroring `evoq_test_assertions` (which is
  in `src/`).
- **Projection assertion** — assert via the projection's own read-model
  accessor (honest, tests the real query path, couples to the domain store) or
  a generic `read_events_by_types` count (decoupled, less honest)?
- **Canonical stream-id helper** — today each aggregate owns `stream_id/1`
  (added to `vehicle_aggregate` in the 2026-05-31 fix, `veh-<md5>`). Should
  evoq ship `evoq_stream_id:derive(Prefix, HumanId)` so every aggregate derives
  compliant ids identically instead of reinventing md5? Arguably the deeper fix
  — sibling proposal.
