%%% @doc DCB Decision behaviour (Dynamic Consistency Boundary).
%%%
%%% A Decision is a write-side construct that sits alongside the
%%% aggregate. Where an aggregate locks on its own stream's version,
%%% a Decision locks on the absence of new events matching a
%%% tag-filter context query. Decisions are for cross-cutting checks
%%% that don't fit the per-entity Dossier shape: uniqueness,
%%% allocation against shared resources, idempotency keys, rate
%%% limits.
%%%
%%% == Callbacks ==
%%%
%%% Required:
%%%   context(Command :: map()) -> context_filter()
%%%     Describe the tag-filter context this decision queries.
%%%     The runtime reads matching events, then passes them to
%%%     decide/2.
%%%
%%%   decide(ContextEvents :: [map()], Command :: map()) ->
%%%       {ok, [Event :: map()]} | {error, Reason :: term()}
%%%     Pure decision function. Given the current context and the
%%%     command, return the events to append OR an error. The
%%%     runtime appends conditionally via the configured event-store
%%%     adapter.
%%%
%%% Optional:
%%%   retry_budget() -> non_neg_integer()
%%%     Maximum retries on context_changed conflicts. Default 3.
%%%
%%% == CCC payload conditions ==
%%%
%%%   The context query can scope on opaque event-data fields, not just
%%%   tags/types: {payload_match, Key, Value} and
%%%   {payload_hash_match, Keys, Values}. The store must declare the
%%%   matching payload index; otherwise the decision fails loudly with
%%%   {error, {payload_index_unavailable, Filter}}. See the
%%%   context_filter() type docs.
%%%
%%% == limitations ==
%%%
%%%   - The runtime considers only events from the DCB pseudo-stream
%%%     (the binary "_dcb"). Mixed-mode use cases (aggregate streams +
%%%     DCB sharing tags) are not supported; use evoq_aggregate if
%%%     the consistency boundary is per-aggregate, evoq_decision
%%%     if it's cross-cutting via DCB.
%%%
%%% @end
-module(evoq_decision).

-export_type([context_filter/0]).

%% Tag-filter for the consistency context. Per-event semantics:
%%   any_of(Tags)            - event has ANY of the given tags
%%   all_of(Tags)            - event has ALL of the given tags
%%   event_type(T)           - event has this event_type (added 1.21.0)
%%   payload_match(K, V)     - event payload field K equals V (CCC, 1.22.0)
%%   payload_hash_match(Ks, Vs) - event payload fields Ks equal Vs (CCC, 1.22.0)
%%   and_(Filters)           - event satisfies ALL sub-filters
%%   or_(Filters)            - event satisfies AT LEAST ONE sub-filter
%%
%% Mirrors reckon_gater_types:tag_filter() exactly, plus the CCC
%% payload-condition leaves. The runtime read path supports compound
%% filters (see evoq_decision_runtime).
%%
%% == CCC payload conditions (added 1.22.0) ==
%%
%% {payload_match, Key, Value} and {payload_hash_match, Keys, Values}
%% query opaque event-data fields rather than tags. The store must
%% declare the matching payload index (`{payload, Key}` /
%% `{payload_hash, Keys}`) — see the reckon-gater CCC guide. A decision
%% using a payload leaf against a store that does not declare the index
%% fails loudly with {error, {payload_index_unavailable, Filter}}; it
%% never silently returns an empty context.
%%
%% Requires reckon-gater >= 3.7 (payload-index introspection;
%% ccc_read_by_payload* reads from 3.6) / reckon-db >= 5.3 for the
%% payload indexes. Tag/type-only decisions have no new requirement.
%%
%% Compound-filter semantics: the runtime reads every leaf of a
%% compound filter fully (via the leaf's own index read), unions the
%% results, and refines client-side. This means {or_, [...]} mixing
%% tag, event_type and payload leaves is correct — each branch is
%% pulled by its own index, not inferred from a sibling.
-type context_filter() ::
      {any_of, [binary()]}
    | {all_of, [binary()]}
    | {event_type, binary()}
    | {payload_match, Key :: binary(), Value :: binary()}
    | {payload_hash_match, Keys :: [binary()], Values :: [binary()]}
    | {and_, [context_filter()]}
    | {or_,  [context_filter()]}.

%% Define the tag-filter context this decision queries.
-callback context(Command :: map()) -> context_filter().

%% Pure decision: given context events + command, return events to
%% append OR an error.
-callback decide(ContextEvents :: [map()], Command :: map()) ->
      {ok, [Event :: map()]}
    | {error, Reason :: term()}.

%% Maximum retries on context_changed conflicts. Default 3.
-callback retry_budget() -> non_neg_integer().
-optional_callbacks([retry_budget/0]).
