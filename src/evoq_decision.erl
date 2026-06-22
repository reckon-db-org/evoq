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
%%% == v1 limitations ==
%%%
%%%   - {or_, [...]} compound filters that mix event_type with tag
%%%     branches may miss events matching only the event_type branch.
%%%     See context_filter() type docs for details.
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
%%   any_of(Tags)         - event has ANY of the given tags
%%   all_of(Tags)         - event has ALL of the given tags
%%   event_type(T)        - event has this event_type (added 1.21.0)
%%   and_(Filters)        - event satisfies ALL sub-filters
%%   or_(Filters)         - event satisfies AT LEAST ONE sub-filter
%%
%% Mirrors reckon_gater_types:tag_filter() exactly. The runtime
%% read path supports compound filters (see evoq_decision_runtime).
%%
%% v1 compound-filter limitation: for {or_, [...]}, the runtime reads
%% a superset via tag + event-type index reads and refines client-side.
%% A pure-event-type branch inside an or_ will match correctly only
%% for events that were already pulled by a sibling tag branch.
%% Use {event_type, T} at the top level or inside {and_, [...]} for
%% fully correct semantics.
-type context_filter() ::
      {any_of, [binary()]}
    | {all_of, [binary()]}
    | {event_type, binary()}
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
