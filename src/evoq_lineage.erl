%% @doc Lineage capability — the EIP correlation/causation identifiers as a
%% first-class, intent-revealing API for evoq applications.
%%
%% These are canonical Enterprise Integration Patterns (Hohpe & Woolf, 2004):
%% every event carries a `correlation_id' (shared across one conversation,
%% copied forward) and a `causation_id' (the id of the message that directly
%% caused it). evoq sets them automatically on dispatch (see
%% {@link evoq_aggregate}); this module is where consumers READ them and
%% QUERY by them without hand-rolling the convention.
%%
%% == Layering ==
%%
%% The reckon event store is generic and polyglot: it stores the ids as
%% reserved metadata keys (`causation_id' / `correlation_id' /
%% `conversation_id', see reckon_shared.proto) and offers exactly one
%% cross-cutting operation, `read_by_metadata(Key, Value)'. It deliberately
%% has NO server-side get_effects / get_causes / causation-graph verb —
%% lineage assembly is a read-model concern (the same stance EventStoreDB
%% takes with its `$by_correlation_id' projection).
%%
%% This module is the BEAM/evoq layer that turns that generic primitive into
%% the named operations the patterns describe. `get_effects/2' and friends
%% are thin wrappers over `read_by_metadata' with the blessed keys. Walking a
%% multi-hop causation chain or building a graph is composed by the
%% application on top of these, not done here and never in the store.
%%
%% @author rgfaber
-module(evoq_lineage).

-include("evoq.hrl").

%% Accessors over an event's metadata map
-export([causation_id/1, correlation_id/1, conversation_id/1]).
%% The wire/query key binaries (single source of truth for the names)
-export([causation_key/0, correlation_key/0, conversation_key/0]).
%% Lineage queries (intent-revealing wrappers over read_by_metadata)
-export([get_effects/2, get_correlated/2, get_conversation/2]).

%%====================================================================
%% Accessors
%%====================================================================

%% @doc The id of the message that directly caused this event, or
%% `undefined'. Tolerant of atom keys (events freshly produced in-process)
%% and binary keys (events round-tripped through JSON storage).
-spec causation_id(map()) -> binary() | undefined.
causation_id(Meta) -> meta_get(Meta, ?EVOQ_META_CAUSATION_ID).

%% @doc The conversation id shared by every event in this chain, or
%% `undefined'.
-spec correlation_id(map()) -> binary() | undefined.
correlation_id(Meta) -> meta_get(Meta, ?EVOQ_META_CORRELATION_ID).

%% @doc The (usually domain-specific) conversation id tying multiple
%% correlations to one conceptual operation, or `undefined'. Optional;
%% only present when an application sets it.
-spec conversation_id(map()) -> binary() | undefined.
conversation_id(Meta) -> meta_get(Meta, ?EVOQ_META_CONVERSATION_ID).

%%====================================================================
%% Canonical key binaries
%%====================================================================
%%
%% Derived from the atom macros in evoq.hrl so the in-BEAM metadata key and
%% the wire/query key can never disagree. These binaries are what
%% read_by_metadata matches on and what reckon_shared.proto documents.

-spec causation_key() -> binary().
causation_key() -> atom_to_binary(?EVOQ_META_CAUSATION_ID, utf8).

-spec correlation_key() -> binary().
correlation_key() -> atom_to_binary(?EVOQ_META_CORRELATION_ID, utf8).

-spec conversation_key() -> binary().
conversation_key() -> atom_to_binary(?EVOQ_META_CONVERSATION_ID, utf8).

%%====================================================================
%% Lineage queries
%%====================================================================

%% @doc Events DIRECTLY caused by the message `MessageId' (i.e. events whose
%% `causation_id' equals it). One hop — compose repeatedly for a chain.
-spec get_effects(atom(), binary()) -> {ok, [map()]} | {error, term()}.
get_effects(StoreId, MessageId) ->
    evoq_event_store:read_by_metadata(StoreId, causation_key(), MessageId).

%% @doc Every event in the conversation `CorrId' (i.e. events whose
%% `correlation_id' equals it).
-spec get_correlated(atom(), binary()) -> {ok, [map()]} | {error, term()}.
get_correlated(StoreId, CorrId) ->
    evoq_event_store:read_by_metadata(StoreId, correlation_key(), CorrId).

%% @doc Every event tied to the conversation `ConvId' (i.e. events whose
%% `conversation_id' equals it). Requires the application to set, and the
%% store to index, the `conversation_id' key.
-spec get_conversation(atom(), binary()) -> {ok, [map()]} | {error, term()}.
get_conversation(StoreId, ConvId) ->
    evoq_event_store:read_by_metadata(StoreId, conversation_key(), ConvId).

%%====================================================================
%% Internal
%%====================================================================

%% @private Read a key from a metadata map, trying the atom key first
%% (in-process events) then its binary form (JSON round-tripped events).
-spec meta_get(map(), atom()) -> binary() | undefined.
meta_get(Meta, AtomKey) when is_map(Meta) ->
    case maps:find(AtomKey, Meta) of
        {ok, V} -> V;
        error -> maps:get(atom_to_binary(AtomKey, utf8), Meta, undefined)
    end;
meta_get(_Meta, _AtomKey) ->
    undefined.
