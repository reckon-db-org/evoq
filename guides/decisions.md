# Decisions: cross-cutting consistency via DCB

*Available in evoq 1.19.0+ (paired with reckon-db 3.1.1+).*

A **Decision** is the write-side construct that sits alongside the
familiar `evoq_aggregate`. Where an aggregate enforces "no new
events on MY stream since version N", a Decision enforces "no event
matching THIS tag-filter has been written since seq N".

The pattern is the cross-cutting complement to per-aggregate
optimistic concurrency. Use a Decision when the invariant the write
must preserve crosses streams:

- **Uniqueness** of a value across the whole store
- **Allocation** of a shared resource (slots, IDs, batches)
- **Rate limits** that span multiple aggregates
- **Eligibility** checks that depend on absence-of-events

For per-aggregate invariants, keep using `evoq_aggregate`.

For background: the underlying primitive is [reckon-db's Dynamic
Consistency Boundary](https://codeberg.org/reckon-db-org/reckon-db/src/branch/main/guides/dcb.md).

---

## The `evoq_decision` behaviour

Implement two callbacks (plus one optional):

```erlang
-module(reserve_slot).
-behaviour(evoq_decision).

-export([context/1, decide/2, retry_budget/0]).

%% Required: declare the tag-filter context this Decision queries.
%% The runtime reads events matching this filter, scoped to the DCB
%% pseudo-stream, and observes the highest seq before calling decide/2.
context(#{slot := SlotId}) ->
    {any_of, [<<"slot:", SlotId/binary>>]}.

%% Required: pure function over (context_events, command) ->
%% events_to_append. No I/O. Re-runs on conflict, so this MUST be
%% deterministic.
decide(ContextEvents, #{slot := SlotId, reserver := Who}) ->
    case is_reserved(ContextEvents) of
        true ->
            {error, slot_already_reserved};
        false ->
            {ok, [#{
                event_type => <<"slot_reserved_v1">>,
                data       => #{slot => SlotId, reserver => Who},
                tags       => [<<"slot:", SlotId/binary>>]
            }]}
    end.

%% Optional: how many context_changed conflicts to retry before
%% surfacing retry_budget_exhausted. Default 3.
retry_budget() -> 5.

is_reserved(Events) ->
    lists:any(
        fun(#{event_type := <<"slot_reserved_v1">>}) -> true;
           (_) -> false
        end, Events).
```

Dispatch it:

```erlang
case evoq_decision_runtime:dispatch(reserve_slot, my_store, Command) of
    {ok, AppendedEvents} ->
        %% Committed. AppendedEvents is what decide/2 returned.
        ok;
    {error, retry_budget_exhausted} ->
        %% Too many concurrent conflicts; caller decides whether to
        %% escalate or give up.
        {error, hot_contention};
    {error, slot_already_reserved} ->
        %% Domain error from decide/2.
        {error, slot_already_reserved};
    {error, Reason} ->
        %% Backend error (Ra unavailable, etc.).
        {error, Reason}
end.
```

---

## What the runtime does

```
loop until budget exhausted:
    Filter   = Mod:context(Command)
    Context  = read events matching Filter from _dcb pseudo-stream
    Cutoff   = max(seq of Context, or -1 if empty)
    case Mod:decide(Context, Command) of
        {error, Reason} -> return {error, Reason}     (domain error,
                                                       no retry)
        {ok, NewEvents} ->
            case backend:append_if_no_tag_matches(
                   Store, Filter, Cutoff, NewEvents) of
                {ok, _LastSeq} -> return {ok, NewEvents}
                {error, {context_changed, _}} ->
                    backoff(); continue            (retry on conflict)
                {error, Reason} -> return {error, Reason}
            end
    end
return {error, retry_budget_exhausted}
```

`decide/2` must be **pure**: the runtime re-runs it on every
conflict, with refreshed context. Side effects (logging, telemetry,
projections) belong outside the decision.

The backoff is exponential with jitter, bounded by a small constant
ceiling so the loop completes within a tight window even under
heavy contention.

---

## Filter algebra

`context_filter()` is a recursive predicate over an event's tag set:

| Shape | Meaning | Example |
|-------|---------|---------|
| `{any_of, [Tag]}` | Match if event carries any of these tags | `{any_of, [<<"slot:42">>]}` |
| `{all_of, [Tag]}` | Match if event carries all of these tags | `{all_of, [<<"slot:42">>, <<"tenant:acme">>]}` |
| `{and_, [Filter]}` | Match if all sub-filters match | `{and_, [F1, F2]}` |
| `{or_, [Filter]}` | Match if any sub-filter matches | `{or_, [F1, F2]}` |

The compound `{and_, _}` and `{or_, _}` shapes compose to arbitrary
depth. The runtime walks the tree, collects the tag-set superset,
reads broadly, and refines client-side using
`reckon_db_dcb_filter`'s per-event semantics.

For flat filters (`any_of` / `all_of`), the runtime issues a direct
tagged read with the appropriate match mode — no superset fan-out.

---

## Decisions vs Aggregates

| | Aggregate | Decision |
|---|---|---|
| Consistency boundary | One stream | Tag-filter (cross-stream) |
| Concurrency check | Stream version | Tag-filter context seq |
| Behaviour | `evoq_aggregate` | `evoq_decision` |
| Where state lives | In the aggregate process (rebuilt from its own events) | Inferred from context events on every dispatch |
| Good for | "Has this account been overdrawn?" | "Has this email been claimed?" |
| Bad for | "Is this email unique?" | "What's the current balance of account 42?" |

A Decision is **stateless across dispatches**. Each invocation reads
fresh context. There's no decision actor, no rehydration, no
passivation. The trade-off: every dispatch pays a read.

Use `evoq_decision` only for invariants you can't model as a
per-aggregate state machine. When in doubt, default to aggregates.

---

## Worked example: email uniqueness

```erlang
-module(register_user).
-behaviour(evoq_decision).

-export([context/1, decide/2]).

context(#{email := Email}) ->
    {any_of, [<<"email:", Email/binary>>]}.

decide(ContextEvents, #{email := Email} = Command) ->
    case already_registered(ContextEvents, Email) of
        true ->
            {error, email_already_registered};
        false ->
            {ok, [#{
                event_type => <<"user_registered_v1">>,
                data       => Command,
                tags       => [<<"email:", Email/binary>>]
            }]}
    end.

already_registered(Events, Email) ->
    lists:any(
        fun(#{event_type := <<"user_registered_v1">>,
              data       := #{email := E}}) when E =:= Email -> true;
           (_) -> false
        end, Events).
```

Caller:

```erlang
case evoq_decision_runtime:dispatch(register_user, my_store,
                                     #{email => <<"alice@example.com">>}) of
    {ok, [_RegisteredEvent]} -> ok;
    {error, email_already_registered} -> {error, email_taken};
    {error, retry_budget_exhausted} -> {error, hot_contention}
end.
```

If two callers race to register the same email:

1. Both read the same empty context (cutoff -1).
2. Both decide to write `user_registered_v1`.
3. The Ra log linearises them. One commits at seq N.
4. The other's transaction observes the new event in the
   tag-filter; the precondition (`no event matching this filter with
   seq > -1`) fails; its commit aborts with
   `{context_changed, N}`.
5. The runtime retries the loser. Its second dispatch reads the
   now-non-empty context, `decide/2` returns `email_already_registered`,
   surfaces to the caller.

Note that `decide/2` is the source of truth for "is this email
taken?" — the backend's precondition only checks "did anything new
happen in this filter?", not "is the domain rule satisfied?"

---

## v1 limitations

- **Flat filters only** are translated by the runtime's read path
  via `read_by_tags`. Compound `{and_, _}` / `{or_, _}` filters
  work end-to-end (the backend supports them), but the runtime
  read currently pulls the broader tag superset and refines
  client-side. For very high-cardinality compound filters,
  consider denormalising to a single composite tag.
- **DCB pseudo-stream only**. The runtime considers only events
  written to the `_dcb` pseudo-stream when computing context.
  Mixed-mode (aggregate streams + DCB sharing tags) is not
  supported by `evoq_decision`; use `evoq_aggregate` if the
  consistency boundary is per-aggregate.

---

## See also

- [reckon-db DCB guide](https://codeberg.org/reckon-db-org/reckon-db/src/branch/main/guides/dcb.md) — primitive-level reference
- [Aggregates guide](aggregates.md) — the per-aggregate sibling pattern
- [Process managers guide](process_managers.md) — for orchestration that needs to span multiple Decisions
