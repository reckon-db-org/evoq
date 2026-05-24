# PROPOSAL: `evoq_pipeline_step` and `evoq_pipeline` behaviours

**Status:** Draft
**Author:** Raf Lefever
**Date:** 2026-05-25
**Related:** [hecate-agents/philosophy/COMMAND_PIPELINES.md](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/philosophy/COMMAND_PIPELINES.md) (canonical conceptual model)

---

## Summary

Add two new behaviours and one runner module to evoq, formalizing the **command pipeline** pattern — the chain-of-responsibility that prepares commands so aggregates remain pure functions of `(State, Payload)`.

- `evoq_pipeline_step` — contract for a single step in a pipeline
- `evoq_pipeline` — contract for declaring a pipeline (list of steps + optional error handler)
- `evoq_pipeline:run/3` and `evoq_pipeline:run_async/3` — synchronous and async runners

The behaviours encode a structural invariant that's already implicit in evoq: aggregates do not read external state during event handling. The pipeline provides the explicit, framework-supported place where external reads happen.

---

## Motivation

### The invariant evoq already implies but does not enforce

`evoq_aggregate` requires `execute/2` and `apply/2` to be deterministic functions of `(State, Payload)` and `(State, Event)` respectively. This is the foundation of event-sourcing replay safety. The framework documents it but does nothing structural to ensure it.

In practice, application authors who need external data for command validation reach for one of two anti-patterns:

1. **Reading from a read model inside `execute/2`, `apply/2`, or the dispatching handler.** This is [Demon 41 — THE Cardinal Sin](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/skills/ANTIPATTERNS_EVENT_SOURCING.md#-demon-41-reading-from-read-models-during-event-flow--the-cardinal-sin). Silent race conditions, replay breakage.

2. **Reading from a read model inside an `evoq_process_manager`'s event-flow code.** Same root cause, different appearance. Same failures.

The existing cure (enrich the event at its source) works when the data lives in the source aggregate. It does not address the case where the consuming domain needs data from a **third** domain that neither the source nor the target owns. That case is common (parking egress saga needs both session state from `entry2exit` and permit status from `pricing`; neither domain "should" enrich events with the other's data).

The structural cure is the **command pipeline**: all external reads happen in named pipeline steps BEFORE the aggregate sees the command. Aggregates stay pure. Cross-domain reads become explicit, declarative, observable, testable.

### Why this belongs in evoq

1. **Universality.** The pattern is needed by every event-sourced system that respects the cardinal-sin invariant. Not Hecate-specific.

2. **Enforcement.** With a framework-level behaviour, downstream code gets the right shape for free. Without it, every application reinvents the pattern with subtle bugs (forgot to timestamp the snapshot, leaked side effects into "supposedly pure" handler code, flattened metadata into payload, keyed idempotency wrongly).

3. **Composability across apps.** A generic `enforce_command_id_idempotency_step` shipped in a shared library can plug into any pipeline. Possible only if the filter contract is framework-level.

4. **Connects cleanly to existing behaviours.** `evoq_responder` exists. `evoq_pipeline` slots between responder and aggregate. The responder produces `{ok, Cmd, Ctx}`; the pipeline processes; the aggregate consumes the enriched output. No new conceptual surface — one more behaviour in the chain.

5. **Telemetry hook.** Framework-level pipelines mean every step is automatically instrumented. Hard to do consistently across apps if every one rolls its own runner.

6. **Low risk, well-understood pattern.** Chain-of-responsibility is decades old. Phoenix Plug, Bondy interceptors, ASP.NET middleware, Rack — all this shape. We're just applying it to event-sourced command processing.

---

## Proposed API

### `evoq_pipeline_step` — single step in a pipeline

```erlang
-module(evoq_pipeline_step).

%% Mandatory callbacks
-callback name() -> atom().
-callback apply(Cmd, Ctx) -> Result when
    Cmd    :: evoq_command:t(),
    Ctx    :: evoq_pipeline:ctx(),
    Result :: {ok,    Cmd1 :: evoq_command:t(), Ctx1 :: evoq_pipeline:ctx()}
            | {skip,  Ctx1 :: evoq_pipeline:ctx()}
            | {halt,  Result :: term()}
            | {error, Reason :: term()}.

%% Optional callbacks
-callback timeout()      -> non_neg_integer() | infinity.
-callback failure_mode() -> fail_fast | fail_soft | {default, term()}.

-optional_callbacks([timeout/0, failure_mode/0]).
```

**Four return shapes, each meaningful:**

- `{ok, Cmd, Ctx}` — proceed with possibly modified command and context. Most common.
- `{skip, Ctx}` — proceed without touching the command. For instrumentation-only steps.
- `{halt, Result}` — successful early termination. Pipeline skips remaining steps, returns Result to caller. Canonical use: idempotency hit.
- `{error, Reason}` — pipeline halts with error.

The `halt` return is load-bearing. It distinguishes successful no-ops (idempotent retries that hit a cached response) from failures. Without it, idempotency steps must fake success by skipping aggregate dispatch in a follow-up check, leaking pipeline knowledge into callers.

### `evoq_pipeline` — pipeline declaration

```erlang
-module(evoq_pipeline).

%% Mandatory callback
-callback steps() -> [module()].

%% Optional callbacks
-callback context_init(Cmd, RawCtx) -> Ctx.
-callback on_error(Reason, Cmd, Ctx, FailedStep) -> Action when
    Action :: propagate
            | {retry, Delay :: non_neg_integer()}
            | {dead_letter, Topic :: binary()}.

-optional_callbacks([context_init/2, on_error/4]).
```

The `steps/0` callback returns the ordered list of step modules. Order matters: enrichment before validation that depends on it.

`context_init/2` is for pipelines that need to bootstrap a derived context from raw request data (e.g., extracting actor identity from a mesh envelope). Default: pass `RawCtx` through unchanged.

`on_error/4` is for pipelines that want custom error handling beyond "propagate to caller." Default: propagate.

### Runner

```erlang
-module(evoq_pipeline).

-export([run/3, run_async/3]).

-spec run(PipelineMod, Cmd, InitialCtx) -> Result when
    PipelineMod :: module(),
    Cmd         :: evoq_command:t(),
    InitialCtx  :: ctx(),
    Result      :: {ok,    FinalCmd :: evoq_command:t(), FinalCtx :: ctx()}
                 | {halt,  Result   :: term()}
                 | {error, Reason   :: term(), FailedStep :: module()}.

-spec run_async(PipelineMod, Cmd, InitialCtx) -> {ok, Ref :: reference()}.
```

`run_async/3` spawns a worker process, runs the pipeline synchronously inside it, and returns a reference the caller can monitor. Result is delivered as `{evoq_pipeline_result, Ref, Result}`.

### Context shape

`Ctx` is a map with reserved framework keys plus arbitrary application keys:

```erlang
-type ctx() :: #{
    %% Reserved framework keys (read-only to steps, set by runner)
    '__pipeline'    => module(),                  % the running pipeline module
    '__started_at'  => non_neg_integer(),         % monotonic_time(microsecond)
    '__step_index'  => non_neg_integer(),         % current step (0-based)

    %% Reserved convention: metadata bound for the dispatched command
    '__meta'        => #{atom() => term()},

    %% Application-defined keys
    atom()          => term()
}.
```

### Metadata propagation convention

Keys placed under `'__meta'` in ctx are auto-serialized into the dispatched command's `metadata` field before the aggregate sees it. This formalizes the payload/metadata separation that [Demon 37 — Flattening Event Envelopes into Business Data](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/skills/ANTIPATTERNS_EVENT_SOURCING.md) demands.

```erlang
%% Inside a step:
apply(Cmd, Ctx) ->
    Cmd1 = Cmd#{permit_id => <<"p1">>, permit_valid_until => 999},
    Ctx1 = put_meta(Ctx, permit_snapshot_at, erlang:system_time(millisecond)),
    Ctx2 = put_meta(Ctx1, permit_source, <<"local_projection">>),
    {ok, Cmd1, Ctx2}.

put_meta(Ctx, Key, Value) ->
    Meta = maps:get('__meta', Ctx, #{}),
    maps:put('__meta', Meta#{Key => Value}, Ctx).
```

After the pipeline completes, the runner moves `Ctx['__meta']` into the dispatched command's metadata field. The aggregate's `execute/2` sees the enriched payload (`permit_id`, `permit_valid_until`) but not the metadata. The emitted event carries both. Downstream consumers (PMs in other domains) can reason about snapshot freshness without re-reading.

### Telemetry events

The runner emits standard telemetry spans:

```
[evoq, pipeline, run, start]
    Measurements: #{}
    Metadata:     #{pipeline, cmd_type, ctx_keys}

[evoq, pipeline, run, stop]
    Measurements: #{duration_us}
    Metadata:     #{pipeline, cmd_type, result}     % ok | halt | error

[evoq, pipeline, step, start]
    Measurements: #{}
    Metadata:     #{pipeline, step, cmd_type}

[evoq, pipeline, step, stop]
    Measurements: #{duration_us}
    Metadata:     #{pipeline, step, cmd_type, result}  % ok | skip | halt | error

[evoq, pipeline, step, exception]
    Measurements: #{}
    Metadata:     #{pipeline, step, kind, reason, stacktrace}
```

Per-step timing visibility for free. Drop-in for `telemetry_metrics`, `prom_ex`, OpenTelemetry exporters.

---

## How it composes with existing evoq behaviours

```
mesh inbound
    ↓
evoq_responder         (HOPE → Command)
    ↓
evoq_pipeline:run/3    (Command + Ctx → EnrichedCommand)
    ↓
evoq_aggregate:execute (EnrichedCommand → Events)
    ↓
evoq_projection / evoq_emitter / evoq_process_manager
    ↓
... downstream ...
```

PMs sit on the other side of the same shape:

```
trigger event (from pg or mesh subscription)
    ↓
evoq_process_manager   (Event → Command)
    ↓
evoq_pipeline:run/3    (Command + Ctx → EnrichedCommand)
    ↓
evoq_aggregate:execute (EnrichedCommand → Events)
```

No existing behaviour changes. The pipeline is an optional intermediate step inserted between request translation and aggregate execution.

---

## Composability

A step that itself wants to run a sub-pipeline does so trivially — it implements `evoq_pipeline_step` and internally calls `evoq_pipeline:run/3`:

```erlang
-module(authenticate_and_authorize_step).
-behaviour(evoq_pipeline_step).

name() -> authenticate_and_authorize.

apply(Cmd, Ctx) ->
    case evoq_pipeline:run(auth_subpipeline, Cmd, Ctx) of
        {ok,   Cmd1, Ctx1}   -> {ok, Cmd1, Ctx1};
        {halt, _} = Halt     -> Halt;
        {error, R, _Step}    -> {error, R}
    end.
```

No framework support needed for composition — the behaviour composes recursively because steps return the same shape the runner consumes.

---

## Test helpers

Optional companion module `evoq_pipeline_test`:

```erlang
-module(evoq_pipeline_test).

-export([run_with_stubs/3, assert_step_emits/3]).

%% Run a pipeline with specific steps replaced by stub functions.
-spec run_with_stubs(PipelineMod, Cmd, StepStubs) -> Result when
    PipelineMod :: module(),
    Cmd         :: evoq_command:t(),
    StepStubs   :: #{module() => fun((Cmd, Ctx) -> evoq_pipeline_step:result())}.
```

Useful for testing pipelines end-to-end with selected steps stubbed (e.g., mock the external-read steps, run the validation steps for real).

---

## Implementation phases

### Phase 1 — Core (~250 LOC)

- `evoq_pipeline_step` behaviour module
- `evoq_pipeline` behaviour module + runner functions
- Telemetry instrumentation
- `evoq_pipeline_test` helpers
- Unit tests for the runner
- One example pipeline in `examples/`

### Phase 2 — Generic steps library (optional, separate package)

If accumulated demand justifies it, a `hecate_pipeline_steps` package (NOT in evoq itself — it has Hecate-specific dependencies):

- `authenticate_via_realm_cert`
- `enforce_command_id_idempotency`
- `attach_actor_to_metadata`
- `record_command_received_audit`

evoq stays domain-agnostic; reusable steps live in their own libraries.

### Phase 3 — Documentation + migration guide

- `guides/pipelines.md` in evoq
- Migration notes for existing evoq users (existing code keeps working unchanged; adopt incrementally)

---

## Package boundary

What lives where:

| In `evoq` | In application / library |
|-----------|---------------------------|
| `evoq_pipeline_step` behaviour | All specific steps (`enrich_with_permit_status`, etc.) |
| `evoq_pipeline` behaviour | All pipeline declarations (`record_exit_pipeline`, etc.) |
| `evoq_pipeline:run/3` runner | Reusable steps in a shared library |
| Telemetry instrumentation | Application-specific test fixtures |
| `evoq_pipeline_test` helpers | |
| Generic shape (ctx map, metadata convention, halt/error/skip semantics) | |

evoq stays domain-agnostic. No Hecate-specific concerns leak into the framework.

---

## Non-goals (v1)

The following are explicitly **out of scope** for the initial behaviour to keep the surface small:

- **Specific reusable steps (auth, idempotency, etc.).** Application-level. Will probably accumulate in a separate `hecate_pipeline_steps` library once 5+ are identified.
- **Worker process management for stateful steps.** Stateful steps delegate to separately-supervised processes via their own internal contract. Pipeline runner stays simple; doesn't manage process lifecycle.
- **Step-level retries inside the runner.** The failing step implements retry internally if needed, OR the entire pipeline is retried by the caller. KISS for v1.
- **Dynamic step lists (`steps/1` branching on command type).** Static `steps/0` only. If a command needs two different chains, that's two commands with two pipelines. Dynamic lists hide what static ones reveal.
- **Async / streaming individual steps.** Individual steps stay synchronous. Async pipelines run via `run_async/3` (whole pipeline in a spawned process).
- **Pipeline versioning.** A pipeline is identified by its module name; changes happen via new modules.

---

## Migration path

Applications that don't use pipelines keep working unchanged. Behaviours are additive.

Applications that want to adopt:

1. Identify a command with external-read dependencies (likely a current Demon 41 offender).
2. Create the pipeline module: declare the step order in `steps/0`.
3. Create one step module per external read.
4. Insert `evoq_pipeline:run/3` between the responder/PM and the aggregate dispatch.
5. Remove the external reads from the aggregate/handler/PM event-flow code.

No breaking changes to existing evoq APIs. Adoption is per-command, per-pipeline.

Applications that have already hand-rolled a runner (e.g., the parksim family, if/when it adopts the pattern from hecate-agents) migrate by:

1. Changing the runner call site from `pipeline_runner:run/3` to `evoq_pipeline:run/3`.
2. Optionally adding the `-behaviour(evoq_pipeline_step)` and `-behaviour(evoq_pipeline)` declarations.

Step modules keep working — the contract was designed to be compatible.

---

## Open questions

1. **Should `Ctx` be a map or an opaque record with accessors?** Map is simpler and more flexible; record gives stronger typing. Lean toward map for v1, revisit if usage shows demand for stricter shape.

2. **Should the runner offer step-level skip-on-condition?** E.g., `apply/2` returns `{ok, Cmd, Ctx#{skip_validation => true}}` and the runner skips downstream steps tagged as validation. Adds complexity; unclear if real-world demand justifies. Likely no for v1.

3. **Should `failure_mode/0` be per-step (as proposed) or declared by the pipeline?** Per-step makes failure semantics travel with the step (good for reusable steps). Pipeline-level allows the same step to behave differently in different pipelines (could be useful but probably more confusing). Per-step is simpler; lean that way.

4. **Telemetry event prefix.** Proposed `[evoq, pipeline, ...]`. Consistent with other evoq telemetry (which uses `[evoq, ...]` family). Confirm.

---

## References

- [hecate-agents/philosophy/COMMAND_PIPELINES.md](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/philosophy/COMMAND_PIPELINES.md) — canonical conceptual model, source of truth for the pattern
- [hecate-agents/skills/codegen/erlang/CODEGEN_ERLANG_PIPELINES.md](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/skills/codegen/erlang/CODEGEN_ERLANG_PIPELINES.md) — templates and checklists
- [hecate-agents/skills/ANTIPATTERNS_EVENT_SOURCING.md#-demon-41](https://codeberg.org/hecate-social/hecate-agents/src/branch/main/skills/ANTIPATTERNS_EVENT_SOURCING.md#-demon-41-reading-from-read-models-during-event-flow--the-cardinal-sin) — Demon 41, the cardinal sin this pattern cures
- Phoenix Plug — Elixir/Erlang precedent for the same shape
- Bondy interceptors — WAMP-layer precedent within the BEAM ecosystem

---

## Decision

Pending. Awaiting review.
