# Domain and Integration Artifacts

evoq distinguishes between **domain artifacts** (internal to a bounded context) and **integration artifacts** (crossing boundaries). This guide explains the 4 artifact types and when to use each.

## The Problem

Without formal contracts, commands and events are untyped maps. This leads to:

- Inconsistent APIs across modules
- Missing callbacks discovered at runtime, not compile time
- No distinction between internal events and external-facing payloads
- No type discovery -- you cannot programmatically ask "what commands exist?"

## The 4 Artifact Types

| Artifact | Level | Key Type | Serialization | Direction |
|----------|-------|----------|---------------|-----------|
| **Command** | Domain | atom | Erlang terms | Inbound (API to aggregate) |
| **Event** | Domain | atom | Erlang terms | Internal (aggregate to handlers) |
| **Fact** | Integration | binary | JSON | Outbound (event to pg/mesh) |
| **Hope** | Integration | binary | JSON | Outbound RPC (agent to agent) |

### Domain Artifacts: Commands and Events

Domain artifacts stay inside the bounded context. They use atom keys because they never leave the BEAM VM.

**Commands** represent intentions. They are validated before execution.

**Events** represent facts. They are immutable once stored. Event construction does not return `{ok, _}` -- if the handler validated the command, the event is always valid.

### Integration Artifacts: Facts and Hopes

Integration artifacts cross boundaries -- between bounded contexts, between BEAM nodes, or between agents over the network. They use binary keys because they must be JSON-serializable.

**Facts** are fire-and-forget. A domain event happens, a fact is published. Nobody waits for a response.

**Hopes** are requests. An agent sends a hope and *hopes* for a response (distributed systems -- no guarantees). Think RPC, but honest about reliability.

## evoq_command

Commands are the entry point to the domain. They carry user intent.

### Callbacks

```erlang
%% Required
-callback command_type() -> atom().
-callback new(Params :: map()) -> {ok, Command} | {error, Reason}.
-callback to_map(Command) -> map().

%% Optional
-callback validate(Command) -> ok | {ok, Command} | {error, Reason}.
-callback from_map(Map :: map()) -> {ok, Command} | {error, Reason}.
```

### Example

```erlang
-module(initiate_venture_v1).
-behaviour(evoq_command).

-record(initiate_venture_v1, {
    venture_id   :: binary(),
    name         :: binary(),
    brief        :: binary() | undefined,
    initiated_by :: binary() | undefined
}).

command_type() -> initiate_venture_v1.

new(#{name := Name} = Params) ->
    {ok, #initiate_venture_v1{
        venture_id = maps:get(venture_id, Params, generate_id()),
        name = Name,
        brief = maps:get(brief, Params, undefined),
        initiated_by = maps:get(initiated_by, Params, undefined)
    }};
new(_) ->
    {error, missing_required_fields}.

validate(#initiate_venture_v1{name = Name}) when
    not is_binary(Name); byte_size(Name) =:= 0 ->
    {error, invalid_name};
validate(Cmd) ->
    {ok, Cmd}.

to_map(#initiate_venture_v1{} = Cmd) ->
    #{
        command_type => initiate_venture_v1,
        venture_id => Cmd#initiate_venture_v1.venture_id,
        name => Cmd#initiate_venture_v1.name,
        brief => Cmd#initiate_venture_v1.brief,
        initiated_by => Cmd#initiate_venture_v1.initiated_by
    }.
```

### Key Points

- `command_type/0` returns an atom, typically the module name
- `to_map/1` MUST include the `command_type` key
- `validate/1` is optional -- use it for domain validation beyond field presence
- `from_map/1` is optional -- use it at API boundaries for deserialization

## evoq_event

Events are the source of truth. They record what happened.

### Callbacks

```erlang
%% Required
-callback event_type() -> atom().
-callback new(Params :: map()) -> Event.
-callback to_map(Event) -> map().

%% Optional
-callback from_map(Map :: map()) -> {ok, Event} | {error, Reason}.
```

### Example

```erlang
-module(venture_initiated_v1).
-behaviour(evoq_event).

-record(venture_initiated_v1, {
    venture_id   :: binary(),
    name         :: binary(),
    brief        :: binary() | undefined,
    initiated_by :: binary() | undefined,
    initiated_at :: integer()
}).

event_type() -> venture_initiated_v1.

new(#{venture_id := VentureId, name := Name} = Params) ->
    #venture_initiated_v1{
        venture_id = VentureId,
        name = Name,
        brief = maps:get(brief, Params, undefined),
        initiated_by = maps:get(initiated_by, Params, undefined),
        initiated_at = erlang:system_time(millisecond)
    }.

to_map(#venture_initiated_v1{} = E) ->
    #{
        event_type => venture_initiated_v1,
        venture_id => E#venture_initiated_v1.venture_id,
        name => E#venture_initiated_v1.name,
        brief => E#venture_initiated_v1.brief,
        initiated_by => E#venture_initiated_v1.initiated_by,
        initiated_at => E#venture_initiated_v1.initiated_at
    }.
```

### Key Points

- `new/1` returns the event directly (no `{ok, _}` wrapper) -- event construction from a validated handler should not fail
- `to_map/1` MUST include the `event_type` key
- `event_type` values can be atoms -- evoq auto-converts to binary for storage
- `from_map/1` is optional -- use it for typed deserialization during replay/rebuild

### Atom event_type in aggregates

When `to_map/1` returns an atom `event_type`, evoq handles the conversion:

- **Storage**: `evoq_aggregate` converts atom to binary via `resolve_event_type/1` before appending to the event store
- **Replay**: Events from the store have binary `event_type` (as stored)
- **Aggregate apply**: Your `apply/2` should handle both atom (fresh execution) and binary (replay). A normalization clause at the top works well:

```erlang
apply_event(#{event_type := Type} = E, S) when is_atom(Type) ->
    apply_event(E#{event_type := atom_to_binary(Type, utf8)}, S);
apply_event(#{event_type := <<"venture_initiated_v1">>} = E, S) ->
    %% handle event...
```

## evoq_fact

Facts translate domain events into integration payloads for external consumers.

### Why Facts Are Separate From Events

Domain events are implementation details. They may change frequently, use internal identifiers, or contain data that external consumers should not see. Facts are explicit public contracts:

- Different name (event: `venture_initiated_v1`, fact: `<<"hecate.venture.initiated">>`)
- Different structure (subset of event data, binary keys)
- Different versioning lifecycle

### Callbacks

```erlang
%% Required
-callback fact_type() -> binary().
-callback from_event(EventType :: atom(), EventData :: map(), Metadata :: map()) ->
    {ok, Payload :: map()} | skip.

%% Optional
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason}.
-callback schema() -> map().
```

### Example

```erlang
-module(venture_initiated_fact_v1).
-behaviour(evoq_fact).

fact_type() -> <<"hecate.venture.initiated">>.

from_event(venture_initiated_v1, Data, _Metadata) ->
    {ok, #{
        <<"venture_id">> => maps:get(venture_id, Data),
        <<"name">> => maps:get(name, Data),
        <<"brief">> => maps:get(brief, Data, null),
        <<"initiated_by">> => maps:get(initiated_by, Data, null),
        <<"initiated_at">> => maps:get(initiated_at, Data)
    }};
from_event(_Other, _Data, _Metadata) ->
    skip.

serialize(Payload) -> evoq_fact:default_serialize(Payload).
deserialize(Binary) -> evoq_fact:default_deserialize(Binary).
```

### Key Points

- `fact_type/0` returns a binary topic string (dot-separated namespace)
- `from_event/3` can return `skip` if a particular event should not produce a fact
- All map keys MUST be binaries (JSON-safe)
- Default `serialize/1` and `deserialize/1` use OTP 27 `json` module -- call `evoq_fact:default_serialize/1` and `evoq_fact:default_deserialize/1`
- Fact modules live in the same desk directory as the event they translate (vertical slicing)

### Where Facts Live

Per the vertical slicing principle, fact modules belong in the same desk as the event:

```
apps/guide_venture_lifecycle/src/initiate_venture/
    initiate_venture_v1.erl           # command
    venture_initiated_v1.erl          # event
    venture_initiated_fact_v1.erl     # fact (translates event for mesh/pg)
    venture_initiated_v1_to_mesh.erl  # emitter (publishes fact to mesh)
    venture_initiated_v1_to_pg.erl    # emitter (publishes fact to pg)
```

## evoq_hope

Hopes are outbound RPC requests. They represent one agent asking another to do something.

### Callbacks

```erlang
%% Required
-callback hope_type() -> binary().
-callback new(Params :: map()) -> {ok, Hope} | {error, Reason}.
-callback to_payload(Hope) -> map().
-callback from_payload(Payload :: map()) -> {ok, Hope} | {error, Reason}.

%% Optional
-callback validate(Hope) -> ok | {error, Reason}.
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason}.
-callback schema() -> map().
```

### Key Points

- Uses `to_payload/from_payload` (not `to_map/from_map`) to distinguish from domain serialization
- `new/1` returns `{ok, Hope}` (unlike events) because RPC requests may fail validation
- No implementations exist yet -- the behaviour is defined for when RPC use cases arise
- Default serialization via `evoq_hope:default_serialize/1` and `default_deserialize/1`

## Backward Compatibility

All behaviours are opt-in:

- Existing command/event modules without `-behaviour(evoq_command)` or `-behaviour(evoq_event)` continue to work exactly as before
- Adding the behaviour declaration gives you compile-time enforcement (warnings for missing callbacks)
- evoq does not require modules to implement these behaviours -- the framework accepts plain maps

## Migration Path

To adopt the behaviours in existing code:

1. Add `-behaviour(evoq_command)` or `-behaviour(evoq_event)` to the module
2. Export `command_type/0` or `event_type/0`
3. Ensure `new/1` and `to_map/1` exist with the expected signatures
4. Add atom normalization to your aggregate's `apply_event/2` if switching `event_type` from binary to atom
5. Optionally create `evoq_fact` modules for events that need external publication
