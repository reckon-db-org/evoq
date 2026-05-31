# DESIGN: evoq CMD-level Domain Testing Framework

**Status:** Draft v2 (2026-05-31) — awaiting approval. No framework code yet.
**Repo:** `reckon-db-org/evoq` (currently v1.19.0).
**Depends on:** `reckon-db-org/mem-evoq` (hex `mem_evoq` 0.1.2) — already exists.

> v2 supersedes v1. v1 framed the gap as "no reusable persistence harness" and
> proposed building a store fixture. Correction: the in-memory adapter already
> exists (`mem-evoq`), and the user's actual intent is a **sequence-driven CMD
> spec with four assertions per step**. This version is built around that.

---

## 1. What we want (user's spec)

Inject a **sequence of commands** into an aggregate. After **each** command,
assert:

1. the aggregate is in the **correct state**;
2. the aggregate **emitted the expected events**;
3. the aggregate emitted **no unexpected events**;
4. the aggregate **did not fail**.

State threads through the sequence: command N runs against the state left by
commands 1..N-1 (folded from their events). This is the pure heart of the
framework — `execute/2` + `apply/2`, no store.

---

## 2. Why — the incident that proves the need

On 2026-05-31 the hecate-parksim fleet ran live: brain ticking, telemetry
flowing, `dispatch` returning `ok` everywhere. Yet the read model was empty
(`trips`/`revenue` 0). Three silent failures nested:

1. **Stream-id rejection.** The aggregate used the human id `leuven-taxi-1` as
   the evoq `AggregateId` == reckon-db stream id. reckon-db requires
   `^[a-z]{1,32}-[a-f0-9]{32}$` (`reckon_gater_stream_id`); every dispatch
   returned `{error, {invalid_stream_id, malformed_user_id, _}}`.
2. **Swallowed dispatch.** The caller did `_ = catch Mod:dispatch(...)` — the
   error vanished. No crash, no log.
3. **Empty projection.** No events persisted → nothing to fold → empty read
   model.

The corpus names this exact class — *"ok without observability is a lie"*. Note
**which layer each bug lives in**, because it dictates the framework's layers:

| Bug | Layer | Caught by |
|-----|-------|-----------|
| wrong/missing event, wrong precondition, wrong state | `execute/2` logic | **Layer A** (pure spec, §4) |
| swallowed dispatch error | call site | **Layer A** asserts `execute` result; **Layer B** asserts `dispatch` result |
| stream-id rejection | adapter/store boundary | **explicit stream-id guard** (§6) — NOT Layer A or B alone |
| projection/subscription not wiring events into the read model | dispatch→store→project | **Layer B** (mem-evoq, §5) |

A blunt honest point: **the four pure assertions would NOT have caught
2026-05-31.** `execute/2` was correct — it emitted the right event. The bug was
downstream at persistence. So the four assertions are necessary but not
sufficient; §5 and §6 cover the rest.

---

## 3. What already exists (reuse, don't rebuild)

| Asset | Role |
|-------|------|
| `evoq_aggregate` behaviour | `state_module/0`, `init/1`, `execute/2 -> {ok,[Event]}|{error,Reason}`, `apply/2`. The contract Layer A drives. |
| `evoq_test_assertions` | `assert_command_succeeds/fails[_with]`, `assert_event[s]_produced`, etc. — but they assert the dispatch RETURN via `evoq_router:dispatch`, not a folded sequence. Layer A reuses the matching helpers; adds sequence + state threading. |
| `evoq_event_store:set_adapter/1` | the swap seam for Layer B. |
| **`mem_evoq` (mem-evoq, hex 0.1.2)** | in-memory `evoq_event_store` adapter: full surface (`append/read/read_all/read_by_event_types/version/exists/list_streams/delete_stream` + snapshots + subscriptions). `mem_evoq:start_store/1,2`. Swap via `application:set_env(evoq, event_store_adapter, mem_evoq_adapter)`. No Khepri/Ra/disk. **This IS Layer B's store.** |
| `reckon_gater_stream_id:validate/1` | the regex check. mem-evoq deps on `reckon_gater` so it's available, but — see §6 — mem-evoq does NOT call it. |

**Verified gap (read mem_evoq_store.erl 2026-05-31):** mem-evoq's append does
**not** validate stream ids — zero `reckon_gater` / `validate` references. So a
scenario with a malformed id passes against mem-evoq while failing in prod.
This is exactly why the stream-id guard (§6) is a SEPARATE explicit assertion,
not an emergent property of Layer B. (And §8 recommends mem-evoq close the gap.)

---

## 4. Layer A — the pure CMD spec (the four assertions)

Drives `execute/2` + `apply/2` directly. The whole loop:

```
State0 = AggMod:init(AggId)                       %% or fold given-events
%% per step {CmdType, Payload, ExpectEvents, StatePred}:
  case AggMod:execute(State, Command) of
      {ok, Events} ->
          assert_event_types(Events, ExpectEvents),   %% (2) AND (3): exact
          State1 = lists:foldl(fun(E,S) -> AggMod:apply(S,E) end, State, Events),
          assert(StatePred(State1)),                   %% (1) correct state
          thread State1 to next step;                  %% (4) implicit: no {error,_}
      {error, Reason} ->
          fail unless this step expected_error(Reason) %% (4)
  end
```

**Assertions 2 + 3 are one check.** Comparing the emitted event-type list to the
expected list *exactly* makes "no unexpected events" free — an extra event is a
mismatch. (`evoq_test_assertions:assert_events_produced/2` already does an exact
multiset/order check; Layer A reuses it.)

**Assertion 1** runs a predicate on the **folded** state via the state module's
**public accessors** (`vehicle_state:is_on_trip/1`, or `to_map/1` + field) —
behaviour, not record-poking (corpus: *"test the behaviour, not the
implementation"*).

**Assertion 4** is structural: a non-error step that returns `{error, _}` fails;
an error step asserts the specific reason.

### Step shape — tuple-list core + builder sugar (both, per request)

Core data form (table-drivable, easy to generate):

```erlang
Scenario = [
  {commission_vehicle, #{vehicle_id => V, ...},
        expect([<<"vehicle_commissioned">>]),
        fun(S) -> vehicle_state:is_commissioned(S) end},
  {dispatch_vehicle, #{vehicle_id => V, ...},
        expect([<<"vehicle_dispatched">>]),
        fun(S) -> vehicle_state:is_dispatched(S) end},
  {pick_up_passenger, #{vehicle_id => V, ...},
        expect([<<"passenger_picked_up">>]),
        fun(S) -> vehicle_state:is_on_trip(S) end},
  {pick_up_passenger, #{vehicle_id => V, ...},
        expect_error(vehicle_not_dispatched),
        unchanged}
],
evoq_aggregate_spec:run(vehicle_aggregate, V, Scenario).
```

Builder sugar over the same engine (readable for long scenarios):

```erlang
evoq_aggregate_spec:new(vehicle_aggregate, V)
  |> exec(commission_vehicle, #{...}) |> emits([<<"vehicle_commissioned">>])
                                      |> state(fun vehicle_state:is_commissioned/1)
  |> exec(dispatch_vehicle, #{...})   |> emits([<<"vehicle_dispatched">>])
  |> exec(pick_up_passenger, #{...})  |> fails_with(vehicle_not_dispatched)
%% (illustrative arrows; real builder threads an opaque spec record — no |> in Erlang)
```

### Module sketch

```erlang
-module(evoq_aggregate_spec).
-export([new/2, given_events/2, exec/3, emits/2, state/2,
         fails_with/2, run/3]).
%% new(AggMod, AggId) -> spec()
%% given_events(spec(), [EventMap]) -> spec()      %% seed state via apply/2
%% exec(spec(), CmdType :: atom(), Payload :: map()) -> spec()  %% records a step
%% emits(spec(), [EventType :: binary()]) -> spec()  %% attaches exact expectation
%% state(spec(), fun((State) -> boolean())) -> spec()
%% fails_with(spec(), Reason :: term()) -> spec()
%% run(AggMod, AggId, [step()]) -> ok               %% tuple-list entry; asserts each step
```

No store, no processes — milliseconds. This is the bulk of domain testing.

---

## 5. Layer B — persistence via mem-evoq (optional, same scenario)

Replays the **same** scenario through the real dispatch path against mem-evoq,
proving events persist and the projection folds them — the half Layer A can't
see.

```erlang
evoq_cmd_case:with_mem_store(fun(StoreId) ->
    ok = evoq_cmd_case:dispatch_all(vehicle_aggregate, V, Scenario, StoreId),
    %% PROVE events landed (read back), not that dispatch returned ok:
    evoq_cmd_case:assert_stream(StoreId, vehicle_aggregate:stream_id(V),
        [<<"vehicle_commissioned">>, <<"vehicle_dispatched">>,
         <<"passenger_picked_up">>]),
    %% Optionally: start the projection, assert the read model:
    evoq_cmd_case:assert_projection(StoreId, vehicle_event_to_read_model,
        fun() -> project_fleet_store:overview() end,
        fun(Ov) -> ?assertEqual(1, maps:get(trips, Ov)) end)
end).
```

`with_mem_store/1`:
- `application:ensure_all_started(mem_evoq)`,
- `mem_evoq:start_store(Unique)`,
- `evoq_event_store:set_adapter(mem_evoq_adapter)` (saves/restores prior),
- runs the fun, `mem_evoq:stop_store/1` after.

`dispatch_all/4` builds `evoq_command:new/5` per step, dispatches via
`evoq_dispatcher:dispatch/2`, and **asserts each returns `{ok,_,_}`** — the
swallow that hid 2026-05-31's bug #2 is structurally impossible here.
`assert_stream/3` reads back via `evoq_event_store:read/5` (or
`read_by_event_types/3`) and compares event types.

```erlang
-module(evoq_cmd_case).
-export([with_mem_store/1, dispatch_all/4, assert_stream/3,
         assert_projection/4]).
```

---

## 6. The stream-id guard (catches today's bug specifically)

Because mem-evoq does NOT enforce the regex (§3), Layer B alone would pass a
malformed id. So the framework offers an **explicit, pure** assertion that
calls the real validator directly:

```erlang
%% in evoq_aggregate_spec (or evoq_cmd_case):
assert_valid_stream_id(AggId) ->
    case reckon_gater_stream_id:validate(AggId) of
        ok -> ok;
        {error, R} -> erlang:error({invalid_stream_id, R, AggId,
                          <<"must match ^[a-z]{1,32}-[a-f0-9]{32}$">>})
    end.
```

A domain author asserts this over their `stream_id/1`:
`assert_valid_stream_id(vehicle_aggregate:stream_id(<<"leuven-taxi-1">>))` →
green; over the raw id → instant red. No store needed; runs in Layer A. This
single line, present in the vehicle suite, would have failed on 2026-05-31.

`dispatch_all/4` also calls it up-front on the AggregateId, so Layer B can't
pass with an id prod would reject — closing the mem-evoq gap at the test
boundary even before mem-evoq itself is fixed (§8).

---

## 7. First consumer: guide_vehicle_lifecycle (retrofit)

Layer-A matrix (the proof-of-use), all 10 commands:

| Command | Prior phase (given) | Expect |
|---------|---------------------|--------|
| `commission_vehicle` | pristine | event `vehicle_commissioned`, state commissioned |
| `commission_vehicle` | commissioned | error `vehicle_already_commissioned` |
| `dispatch_vehicle` | cruising/commissioned | event `vehicle_dispatched`, state dispatched |
| `pick_up_passenger` | dispatched | event `passenger_picked_up`, state on_trip |
| `pick_up_passenger` | pristine | error `vehicle_not_dispatched` |
| `drop_off_passenger` | on_trip | event `passenger_dropped_off`, state cruising |
| `drop_off_passenger` | dispatched | error (not on trip) |
| `return_vehicle` | cruising | event `vehicle_returning`, state returning |
| `dock_at_facility` | returning | event `vehicle_docked_at_facility`, state docked |
| `service_vehicle` | docked | event `vehicle_serviced`, state servicing |
| `release_vehicle` | servicing | event `vehicle_released`, state cruising |
| `deplete_battery` | on_trip | event `battery_depleted`, state depleted |

Plus: one Layer-B happy-path sequence (`commission→dispatch→pickup→dropoff`)
asserting persistence + `trips = 1`, and one `assert_valid_stream_id` over
`vehicle_aggregate:stream_id/1`. These three would each have failed on
2026-05-31.

---

## 8. Recommendation to mem-evoq (sibling change)

mem-evoq's README calls itself *"a reference implementation of the
`evoq_event_store` adapter behaviour."* But reckon-db rejects malformed stream
ids and mem-evoq does not — so it is NOT a faithful reference for that contract,
and tests pass against it that fail in prod (the 2026-05-31 trap). Recommend
mem-evoq add an **opt-in strict mode** (`start_store(Id, #{strict_stream_id =>
true})`) that runs `reckon_gater_stream_id:validate/1` in `append`, mirroring
reckon-db. Then Layer B with strict mode catches the bug class by itself, and
the §6 guard becomes belt-and-suspenders. Filed as a separate proposal in
mem-evoq if approved.

---

## 9. Non-goals

- Not a mocking framework. Layer B uses the real mem-evoq adapter + real
  dispatch path.
- Not a mesh/integration-fact tester. Stops at the local store + projection.
- Not a property generator (`test/property/` stays separate; could feed it the
  scenario form later).
- No runtime changes to `evoq_aggregate`/`evoq_dispatcher` — test support only.

---

## 10. Rollout

1. `evoq_aggregate_spec` (Layer A) + `evoq_cmd_case` (Layer B) + the stream-id
   guard, in evoq `src/` (usable from consumers' test suites, like
   `evoq_test_assertions`), with evoq self-tests using its internal test
   aggregate + mem-evoq.
2. Add `mem_evoq` as a `{test, ...}` profile dep of evoq (or document it as a
   consumer test dep — decide in review; evoq must not gain a prod dep on a
   test store).
3. Minor bump (1.19 → 1.20); `guides/cmd_testing.md`.
4. First consumer: hecate-parksim `guide_vehicle_lifecycle` (§7) — locks the
   regression.
5. Optional: the mem-evoq strict-mode change (§8).

---

## 11. Open questions for the reviewer

- **Layer A reuse vs new** — build `evoq_aggregate_spec` purely as sugar over
  `evoq_test_assertions`, or as a standalone engine that calls `execute/2`+
  `apply/2` directly? The state-threading + `apply/2` fold is the new part
  `evoq_test_assertions` lacks; leaning standalone engine that *uses* the
  assertion helpers for the event comparison.
- **mem-evoq as evoq test dep** — acceptable for evoq's own test profile to dep
  on mem-evoq, given mem-evoq already deps on evoq? (No cycle at runtime — it's
  test-only — but worth a conscious nod.)
- **Strict stream-id in mem-evoq (§8)** — do it as part of this work, or a
  separate mem-evoq proposal?
- **State predicate ergonomics** — predicate fun on folded state (as sketched),
  or also offer `expect_state_map(#{field => value})` sugar that checks
  `to_map/1` fields?
