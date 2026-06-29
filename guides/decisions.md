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

`context_filter()` is a recursive predicate over an event's tags,
type, and (with CCC) payload fields:

| Shape | Meaning | Example |
|-------|---------|---------|
| `{any_of, [Tag]}` | Match if event carries any of these tags | `{any_of, [<<"slot:42">>]}` |
| `{all_of, [Tag]}` | Match if event carries all of these tags | `{all_of, [<<"slot:42">>, <<"tenant:acme">>]}` |
| `{event_type, T}` | Match if event has this type *(1.21.0+)* | `{event_type, <<"slot_reserved_v1">>}` |
| `{payload_match, K, V}` | Match if payload field `K` equals `V` *(CCC, 1.22.0+)* | `{payload_match, <<"license_key">>, <<"LK-1">>}` |
| `{payload_hash_match, Ks, Vs}` | Match if payload fields `Ks` equal `Vs` *(CCC, 1.22.0+)* | `{payload_hash_match, [<<"realm">>,<<"email">>], [<<"acme">>,<<"a@x">>]}` |
| `{and_, [Filter]}` | Match if all sub-filters match | `{and_, [F1, F2]}` |
| `{or_, [Filter]}` | Match if any sub-filter matches | `{or_, [F1, F2]}` |

Flat filters hit their own index directly: `any_of`/`all_of` via the
tag index, `event_type` via `[by_event_type]`, the payload leaves via
the CCC payload indexes (see below).

Compound `{and_, _}` / `{or_, _}` shapes compose to arbitrary depth.
The runtime reads **every leaf fully** through its own index, unions
the results, and refines client-side with `reckon_db_dcb_filter`'s
per-event semantics. Because each branch is pulled by its own index
(not inferred from a sibling), an `{or_, [...]}` mixing tag,
`event_type`, and payload leaves is correct.

---

## CCC: payload conditions

*Available in evoq 1.22.0+ (requires reckon-gater 3.7+ / reckon-db 5.3+).*

Tags and types are explicit labels the producer attaches at write
time. **CCC** (Command Context Consistency) lets a Decision's
boundary instead query **opaque event-data fields** — values already
inside the event payload, with no tagging ceremony. This is an
extension *beyond* the DCB spec, made possible by reckon-db's payload
indexes.

```erlang
%% Uniqueness on a payload field rather than a tag.
context(#{license_key := Key}) ->
    {payload_match, <<"license_key">>, Key}.

%% Composite: this (realm, email) pair must be unique.
context(#{realm := R, email := E}) ->
    {payload_hash_match, [<<"realm">>, <<"email">>], [R, E]}.
```

The write/condition side needs nothing new — reckon-db evaluates
payload filters inside the same atomic append check. Only the context
**read** uses the payload index.

### Declare the index, or fail loud

A payload leaf requires the store to declare the matching index
(`{payload, Key}` for `payload_match`, `{payload_hash, Keys}` for
`payload_hash_match`). A Decision that references an **undeclared**
index fails **loudly and early**:

```erlang
{error, {payload_index_unavailable, {payload_match, <<"license_key">>, <<"LK-1">>}}}
```

It never silently returns an empty context and lets a bad decision
through. The runtime checks the declared indexes (via
`evoq_event_store:payload_indexes/1`) before reading; an old adapter
without introspection is treated the same as an undeclared index.

When to reach for CCC over tags: when the value you must constrain is
already a first-class field of the event (a license key, an external
id, a (realm, email) pair) and tagging it would just duplicate data
the payload already carries.

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

By default a Decision is **stateless across dispatches**: each
invocation reads fresh context, and the trade-off is that every
dispatch pays a read. For a *keyed, hot* boundary you can opt into a
stateful actor that caches the context — see the next section.

Use `evoq_decision` only for invariants you can't model as a
per-aggregate state machine. When in doubt, default to aggregates.

---

## Stateful decision actor (opt-in)

*Available in evoq 1.23.0+.*

For a boundary that is **keyed and hot** — one seat, one account, one
SKU taking many concurrent commands — the stateless path thrashes:
N concurrent commands each read, decide, and race to append, so N−1
hit `context_changed` and retry. The **stateful actor** is the cure,
and it reuses the aggregate's process machinery wholesale.

Opt in by implementing `boundary_key/1`. Return a stable key for the
command's boundary, and the runtime routes the command to a per-node
`gen_server` keyed on it; return `undefined` (or omit the callback)
and you get today's stateless path, verbatim.

```erlang
-module(reserve_seat).
-behaviour(evoq_decision).

-export([context/1, decide/2, boundary_key/1,
         init_decision_model/0, apply_context_event/2]).

%% Opt into the actor: one process per seat.
boundary_key(#{seat := SeatId}) -> SeatId.

context(#{seat := SeatId}) ->
    {any_of, [<<"seat:", SeatId/binary>>]}.

%% Optional folded model. When init/apply are present, decide/2
%% receives the folded Model instead of the raw context-events list
%% (mirrors evoq_aggregate's init/apply).
init_decision_model() -> false.                     % seat not yet taken
apply_context_event(_Model, #{event_type := <<"seat_reserved_v1">>}) -> true;
apply_context_event(Model, _Event) -> Model.

decide(Taken, #{seat := SeatId, who := Who}) ->
    case Taken of
        true  -> {error, seat_taken};
        false -> {ok, [#{event_type => <<"seat_reserved_v1">>,
                         data => #{seat => SeatId, who => Who},
                         tags => [<<"seat:", SeatId/binary>>]}]}
    end.
```

Dispatch is unchanged — `evoq_decision_runtime:dispatch/3` is a facade
that routes to the actor when `boundary_key/1` yields a key.

### What the actor does

- **First command** lazily loads context once, folds it into the
  cached model, records the cutoff.
- **Each command** serialises at the one process (mailbox ordering →
  no thrash), runs `decide/2` against the cached model, appends, and
  on success folds the new events in and advances the cutoff — **no
  re-read**.
- **On `context_changed`** (a second node, or another writer) it
  invalidates, re-reads context, and retries within `retry_budget`.
- **When idle** it passivates and is rebuilt on next use.

The store's `append_if_no_tag_matches` stays the **sole** correctness
authority. The actor is a per-node cache + serialiser, never the
source of truth — a second node may hold its own actor for the same
boundary, and the store backstops the cross-node race.

### When to use which

| Boundary shape | Mode |
|---|---|
| keyed + hot + (near-)disjoint (seat, account, SKU) | **stateful actor** (`boundary_key/1`) |
| keyed but cold / one-shot (email uniqueness at signup) | stateless (default) |
| compound / no natural partition key | stateless (default) |
| per-entity lifecycle | it's an **aggregate**, not a decision |

> **Contract:** for a given `boundary_key`, `context/1` must resolve to
> the same filter for every command — the actor caches one context per
> key. Keep the key and the context derived from the same boundary
> identity.

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

- **Compound filters read every leaf.** `{and_, _}` / `{or_, _}` are
  correct for any mix of tag, `event_type`, and payload leaves (each
  branch is pulled by its own index, then refined client-side). The
  cost is one indexed read per leaf; for very high-cardinality
  compound filters, consider denormalising to a single composite tag
  or payload field.
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
