%% @doc State behaviour for evoq aggregates.
%%
%% The state module is the "default read model" — it owns the aggregate's
%% state record, knows how to create initial state, apply events to update
%% state, and serialize/deserialize state for feedback and snapshots.
%%
%% Every aggregate MUST have a corresponding state module. The aggregate
%% declares it via the state_module/0 callback, and delegates state
%% operations to it:
%%
%%   %% In the aggregate:
%%   state_module() -> venture_state.
%%   init(AggregateId) -> {ok, venture_state:new(AggregateId)}.
%%   apply(State, Event) -> venture_state:apply_event(State, Event).
%%
%% This separation keeps the aggregate focused on command validation and
%% business rules, while the state module owns the data shape, field
%% access, event folding, and serialization.
%%
%% == Required Callbacks ==
%%
%% - new(AggregateId) -> State
%% - apply_event(State, Event) -> State
%% - to_map(State) -> map()
%%
%% == Optional Callbacks ==
%%
%% - from_map(Map) -> {ok, State} | {error, Reason}
%%
%% @author rgfaber
-module(evoq_state).

%% Required callbacks

%% Create initial (empty) state for a new aggregate.
-callback new(AggregateId :: binary()) -> State :: term().

%% Apply a single event to update state. Must be pure and deterministic.
%% Called for each event produced by execute/2 and during replay.
-callback apply_event(State :: term(), Event :: map()) -> State :: term().

%% Serialize state to a map. Used for session-level consistency feedback,
%% snapshot serialization, and programmatic state inspection.
-callback to_map(State :: term()) -> map().

%% Optional callbacks

%% Deserialize state from a map. Used for snapshot loading and
%% state reconstruction from external sources.
-callback from_map(Map :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.

-optional_callbacks([from_map/1]).
