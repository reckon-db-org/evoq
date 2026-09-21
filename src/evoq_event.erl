%% @doc Event behavior for evoq.
%%
%% Events represent facts that have happened. They are:
%% - Past tense: account_opened, money_deposited
%% - Immutable once stored
%% - Produced by aggregates in response to commands
%% - Domain artifacts: atom keys, Erlang terms, stay inside bounded context
%%
%% == The event type discriminator ==
%%
%% `event_type/0' may return an atom OR a binary, and both are first class.
%% A binary is the canonical STORED form. An atom is accepted and converted
%% on the way to the store by `evoq_aggregate:resolve_event_type/1', which
%% has an `is_atom' clause calling `atom_to_binary/2' and an `is_binary'
%% clause that passes through.
%%
%% Every layer beneath this behaviour is binary-only, and was before this
%% spec said so: the decision filters in `evoq_decision' take
%% {event_type, binary()}, `evoq_decision_runtime' reads the by_event_type
%% index by binary, reckon_gater's shared event record types the field
%% binary(), and reckon_db guards is_binary on its index paths. An
%% atom-only spec described neither this library's own runtime nor anything
%% it writes to.
%%
%% In practice Erlang implementations return atoms, which is what the
%% hecate-sdk code generator emits, and Elixir implementations return
%% strings. Both converge on the same stored discriminator, so the two
%% conventions interoperate rather than compete. The "atom keys, Erlang
%% terms" note above is about an event's PAYLOAD, which does stay inside
%% the bounded context; the discriminator is the one field that does not,
%% because it is the wire and index key.
%%
%% == Required Callbacks ==
%%
%% - event_type() -> atom() | binary()
%% - new(Params) -> Event
%% - to_map(Event) -> map()
%%
%% == Optional Callbacks ==
%%
%% - from_map(Map) -> {ok, Event} | {error, Reason}
%%
%% @author rgfaber
-module(evoq_event).

%% Required callbacks
-callback event_type() -> atom() | binary().
-callback new(Params :: map()) -> Event :: term().
-callback to_map(Event :: term()) -> map().

%% Optional callbacks
-callback from_map(Map :: map()) -> {ok, Event :: term()} | {error, Reason :: term()}.

-optional_callbacks([from_map/1]).
