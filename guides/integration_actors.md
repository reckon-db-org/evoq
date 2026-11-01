# Integration Actors

evoq provides 4 actor behaviours for moving integration artifacts across boundaries, plus a feedback type for RPC responses.

## Overview

| Actor | What It Does | Input | Output | Behaviour |
|-------|-------------|-------|--------|-----------|
| **Emitter** | Publishes facts from domain events | Domain event | Fact | `evoq_emitter` |
| **Listener** | Receives facts, dispatches commands | Fact | Command | `evoq_listener` |
| **Requester** | Sends hopes, receives feedback | Hope | Feedback | `evoq_requester` |
| **Responder** | Receives hopes, returns feedback | Hope | Feedback | `evoq_responder` |

`evoq_emitter` is a **contract, not a runtime**: the behaviour declares the
callbacks, and the application supplies the process that runs them, under
its own supervisor. evoq does not start emitters for you.

Emitting is also a decision, not a reflex: not every domain event is an
integration fact. The desk decides which events leave the bounded context
and in what shape (see the process-manager pattern in
`process_managers.md`), rather than one emitter per event mirroring
internal structure onto the wire.

## evoq_emitter

Emitters subscribe to domain events and publish them as integration facts to external transports (pg or mesh).

### Callbacks

```erlang
-behaviour(evoq_emitter).

%% Required
-callback source_event() -> atom().
-callback fact_module() -> module().
-callback transport() -> pg | mesh.
-callback emit(FactType :: binary(), Payload :: map(), Metadata :: map()) ->
    ok | {error, Reason :: term()}.
```

### Example

```erlang
-module(emit_venture_initiated_v1_to_pg).
-behaviour(evoq_emitter).

source_event() -> venture_initiated_v1.
fact_module() -> venture_initiated_fact_v1.
transport() -> pg.

%% pg has no send: a publisher looks the group's members up and sends to
%% each, which is how evoq's own consistency fan-out does it.
emit(FactType, Payload, _Metadata) ->
    Message = {fact, FactType, Payload},
    lists:foreach(fun(Pid) -> Pid ! Message end, pg:get_members(pg, FactType)),
    ok.
```

### Naming and Placement

- **Naming:** `emit_{event}_to_{transport}` (e.g., `emit_venture_initiated_v1_to_pg`)
- **Placement:** Source desk (the desk producing the event)
- **Supervision:** Desk supervisor starts emitters as workers

## evoq_listener

Listeners receive integration facts from external transports and dispatch commands to the local aggregate.

### Callbacks

```erlang
-behaviour(evoq_listener).

%% Required
-callback source_fact() -> binary().
-callback transport() -> pg | mesh.
-callback handle_fact(FactType :: binary(), Payload :: map(), Metadata :: map()) ->
    ok | skip | {error, Reason :: term()}.
```

### Example

```erlang
-module(on_venture_initiated_from_pg_initiate_division).
-behaviour(evoq_listener).

source_fact() -> <<"ventures.venture_initiated">>.
transport() -> pg.

handle_fact(_FactType, Payload, _Metadata) ->
    case initiate_division_v1:from_fact(Payload) of
        {ok, Cmd} ->
            maybe_initiate_division:dispatch(Cmd),
            ok;
        {error, _} ->
            skip
    end.
```

### Naming and Placement

- **Naming:** `on_{fact}_from_{transport}_{command}` (e.g., `on_venture_initiated_from_pg_initiate_division`)
- **Placement:** Own slice directory in the target CMD app (like process managers)
- **Supervision:** Own supervisor in its slice directory

## evoq_requester

Requesters send hopes over mesh and wait for feedback (cross-daemon RPC).

### Callbacks

```erlang
-behaviour(evoq_requester).

%% Required
-callback hope_module() -> module().
-callback send(Hope :: term(), Opts :: map()) ->
    {ok, Feedback :: map()} | {error, Reason :: term()}.
```

### Naming

- **Naming:** `request_{hope_type}` (e.g., `request_discover_venture`)

## evoq_responder

Responders receive hopes, dispatch commands, and return feedback with the post-event aggregate state.

### Callbacks

```erlang
-behaviour(evoq_responder).

%% Required
-callback hope_type() -> binary().
-callback handle_hope(HopeType :: binary(), Payload :: map(), Metadata :: map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

%% Optional
-callback feedback_module() -> module().
```

### Naming

- **Naming:** `{command}_responder_v1` (e.g., `initiate_venture_responder_v1`)

## evoq_feedback

Feedback is the response to a Hope. It carries the result of command execution for session-level consistency.

### Callbacks

```erlang
-behaviour(evoq_feedback).

%% Required
-callback feedback_type() -> binary().
-callback from_result({ok, State :: term()} | {error, Reason :: term()}) -> map().
-callback to_result(Payload :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.

%% Optional (defaults use the OTP json module, in OTP since 27)
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason :: term()}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason :: term()}.
```

Default serialization: `evoq_feedback:default_serialize/1` and `default_deserialize/1`.

## Session Consistency

evoq deliberately departs from one line of the CQRS literature here, and the
departure is the feature.

The reference model says a command handler returns only a status: the caller
learns the outcome, and any state it needs comes from a projection, later.
evoq's `dispatch/2` returns the events the command produced and
`dispatch_with_state/2` returns the aggregate's state as well:

```erlang
%% Standard dispatch: what changed
{ok, Version, Events} = evoq_router:dispatch(Command, Opts).

%% Session consistency: what changed, and the state it left behind
{ok, Version, Events, AggregateState} =
    evoq_command_router:dispatch_with_state(Command, Opts).
```

⚠ **A 3-tuple from `dispatch_with_state/2` means a middleware answered and
nothing ran.** A `before_dispatch` middleware may halt the pipeline and respond
`{ok, Version, Events}` — a cache hit of its own, a replay, a policy that says
"yes, already done". The command never reaches an aggregate, so there is no
post-event state to carry, and the response is returned exactly as the
middleware gave it:

```erlang
%% A middleware that answered, and a command that ran, are both ordinary answers.
answer(Result) ->
    case Result of
        {ok, Version, Events, State} ->
            {Version, Events, State};
        {ok, Version, Events} ->
            {Version, Events, no_state_ran};
        {error, Reason} = Error ->
            {failed, Reason, Error}
    end.
```

That third clause is not an evoq failure mode to work around: it is the
middleware's answer, and it is in the spec so a dialyzed caller has to say what
it does with it. Padding the state with `undefined` was the alternative and is
worse — a caller cannot tell it from an aggregate whose state really is
`undefined`.

A response that is NOT one of those shapes is refused rather than passed through:
`evoq_middleware:respond/2` takes any term, and a middleware answering `ok` or
`{rejected, Why}` would otherwise reach you from a function whose spec says it
cannot. You get `{error, {invalid_middleware_response, Response}}` — a named
refusal, the same fail-closed line as a halt that says nothing.

The name is **session consistency**: within one session - one request, one
user, one process manager step - the caller sees its own write immediately,
without waiting for a projection to catch up. It is not strong consistency
across the system (a projection may still lag, and another session may still
read an older version); it is the guarantee that *you* do not have to
poll your own read model to find out what you just did.

Why it stays:

- A responder answering an RPC needs the post-command state to build its
  reply. Without it, every responder either re-reads a projection it may
  already have outrun, or returns a version number the caller cannot use.
- A process manager deciding its next command has the same problem one
  step removed.
- Event sourcing makes the state derivable from the events in hand, so the
  extra return value costs one fold, not another round trip.

`dispatch/2` is unchanged: callers that want only what happened get a
version and the events.

## Complete Desk Example

```text
apps/guide_venture_lifecycle/src/initiate_venture/
    initiate_venture_v1.erl                 # Command (evoq_command)
    venture_initiated_v1.erl                # Event (evoq_event)
    venture_initiated_fact_v1.erl           # Fact (evoq_fact)
    emit_venture_initiated_v1_to_pg.erl     # Emitter (evoq_emitter)
    emit_venture_initiated_v1_to_mesh.erl   # Emitter (evoq_emitter)
    maybe_initiate_venture.erl              # Handler
    initiate_venture_api.erl                # API entry point
    initiate_venture_responder_v1.erl       # Responder (evoq_responder)
    initiate_venture_desk_sup.erl           # Supervisor
```

## Backward Compatibility

All actor behaviours are opt-in:
- Existing emitters/listeners implemented as plain gen_servers continue to work
- Adding the behaviour gives compile-time enforcement of required callbacks
- `dispatch_with_state/2` is additive -- `dispatch/2` is unchanged
