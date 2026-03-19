# Integration Actors

evoq provides 4 actor behaviours for moving integration artifacts across boundaries, plus a feedback type for RPC responses.

## Overview

| Actor | What It Does | Input | Output | Behaviour |
|-------|-------------|-------|--------|-----------|
| **Emitter** | Publishes facts from domain events | Domain event | Fact | `evoq_emitter` |
| **Listener** | Receives facts, dispatches commands | Fact | Command | `evoq_listener` |
| **Requester** | Sends hopes, receives feedback | Hope | Feedback | `evoq_requester` |
| **Responder** | Receives hopes, returns feedback | Hope | Feedback | `evoq_responder` |

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
    ok | {error, Reason}.
```

### Example

```erlang
-module(emit_venture_initiated_v1_to_pg).
-behaviour(evoq_emitter).

source_event() -> venture_initiated_v1.
fact_module() -> venture_initiated_fact_v1.
transport() -> pg.

emit(FactType, Payload, _Metadata) ->
    pg:send(pg, venture_initiated_v1, {venture_initiated_v1, Payload}),
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
    ok | skip | {error, Reason}.
```

### Example

```erlang
-module(on_venture_initiated_from_pg_initiate_division).
-behaviour(evoq_listener).

source_fact() -> <<"hecate.venture.initiated">>.
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
    {ok, Feedback :: map()} | {error, Reason}.
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
    {ok, State :: term()} | {error, Reason}.

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
-callback from_result({ok, State} | {error, Reason}) -> map().
-callback to_result(Payload :: map()) -> {ok, State} | {error, Reason}.

%% Optional (defaults use OTP 27 json module)
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason}.
```

Default serialization: `evoq_feedback:default_serialize/1` and `default_deserialize/1`.

## Session-Level Consistency

The `dispatch_with_state/2` function enables session-level consistency:

```erlang
%% Standard dispatch
{ok, Version, Events} = evoq_dispatcher:dispatch(Command, Opts).

%% Dispatch with state (for session-level consistency)
{ok, Version, Events, AggregateState} = evoq_dispatcher:dispatch_with_state(Command, Opts).
```

The aggregate state after applying all new events is included in the response. This allows responders to return immediate truth to requesters without waiting for projections.

## Complete Desk Example

```
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
