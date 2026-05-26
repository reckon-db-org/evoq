%%% @doc DCB Decision behaviour (Dynamic Consistency Boundary).
%%%
%%% A `Decision` is a write-side construct that sits alongside the
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
%%%     `decide/2`.
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
%%%   - `context_filter()` only supports `any_of` / `all_of`. Compound
%%%     `and_` / `or_` filters are supported by the backend's
%%%     conditional-append check but the runtime's read path doesn't
%%%     yet translate them; flat filters only.
%%%   - The runtime considers only events from the DCB pseudo-stream
%%%     (`<<"_dcb">>`). Mixed-mode use cases (aggregate streams +
%%%     DCB sharing tags) are not supported; use `evoq_aggregate` if
%%%     the consistency boundary is per-aggregate, `evoq_decision`
%%%     if it's cross-cutting via DCB.
%%%
%%% @end
-module(evoq_decision).

-export_type([context_filter/0]).

%% v1: flat tag predicates only. The backend supports compound
%% `and_` / `or_` for conditional-append, but the runtime's read path
%% doesn't translate them yet.
-type context_filter() ::
      {any_of, [binary()]}
    | {all_of, [binary()]}.

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
