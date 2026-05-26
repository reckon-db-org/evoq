%%% @doc Runtime for the `evoq_decision` behaviour.
%%%
%%% Wires the user-facing callback contract (`context/1`, `decide/2`)
%%% to the event-store adapter's conditional-append primitive
%%% (`append_if_no_tag_matches/4`):
%%%
%%%   1. Call `Mod:context(Command)` to get the tag-filter.
%%%   2. Read the context events matching that filter (DCB-stream only).
%%%   3. Compute the seq cutoff from the highest version seen
%%%      (or -1 for "saw nothing").
%%%   4. Call `Mod:decide(ContextEvents, Command)`.
%%%   5. Conditionally append the resulting events.
%%%   6. On `{error, {context_changed, _}}`, sleep with bounded
%%%      exponential backoff + jitter, then retry from step 2. Retries
%%%      are bounded by `Mod:retry_budget/0` (default 3).
%%%
%%% Returns:
%%%   - `{ok, [Event]}` — events appended; commit produced.
%%%   - `{error, retry_budget_exhausted}` — too many context_changed
%%%     conflicts. Caller decides whether to escalate or give up.
%%%   - `{error, Reason}` — domain error from `decide/2` or backend
%%%     error from the append path. Propagated as-is.
%%% @end
-module(evoq_decision_runtime).

-export([dispatch/3]).

%% Default knobs. Override via application env or per-call options
%% (options API is a v2 concern).
-define(DEFAULT_RETRY_BUDGET, 3).
-define(DEFAULT_BASE_BACKOFF_MS, 5).
-define(DEFAULT_MAX_BACKOFF_MS, 100).
-define(DEFAULT_BATCH_SIZE, 1000).

%% The DCB pseudo-stream id. v1 runtime considers only events from
%% this stream for the consistency check. (Backend-defined; if this
%% ever needs to be configurable, expose via app env.)
-define(DCB_STREAM_ID, <<"_dcb">>).

%%====================================================================
%% Public API
%%====================================================================

-spec dispatch(module(), StoreId :: atom(), Command :: map()) ->
      {ok, [map()]}
    | {error, retry_budget_exhausted}
    | {error, term()}.
dispatch(Mod, StoreId, Command) ->
    Budget = retry_budget(Mod),
    dispatch_loop(Mod, StoreId, Command, Budget).

%%====================================================================
%% Internal
%%====================================================================

dispatch_loop(_Mod, _StoreId, _Command, 0) ->
    {error, retry_budget_exhausted};
dispatch_loop(Mod, StoreId, Command, Retries) ->
    Filter = Mod:context(Command),
    {ok, ContextEvents} = read_context(StoreId, Filter),
    Cutoff = compute_cutoff(ContextEvents),
    case Mod:decide(ContextEvents, Command) of
        {error, _} = DecideError ->
            DecideError;
        {ok, NewEvents} when is_list(NewEvents) ->
            attempt_append(Mod, StoreId, Command, Filter, Cutoff, NewEvents, Retries)
    end.

attempt_append(Mod, StoreId, Command, Filter, Cutoff, NewEvents, Retries) ->
    case evoq_event_store:append_if_no_tag_matches(
           StoreId, Filter, Cutoff, NewEvents) of
        {ok, _LastSeq} ->
            {ok, NewEvents};
        {error, {context_changed, _MaxSeq}} ->
            backoff(Retries),
            dispatch_loop(Mod, StoreId, Command, Retries - 1);
        {error, _} = BackendError ->
            BackendError
    end.

%% Read all events matching the tag filter, then filter to DCB-stream
%% events only (v1 limitation: mixed-mode is unsupported).
read_context(StoreId, {any_of, Tags}) ->
    read_filtered_to_dcb(StoreId, Tags, any);
read_context(StoreId, {all_of, Tags}) ->
    read_filtered_to_dcb(StoreId, Tags, all).

read_filtered_to_dcb(StoreId, Tags, Match) ->
    case evoq_event_store:read_by_tags(StoreId, Tags, Match, ?DEFAULT_BATCH_SIZE) of
        {ok, AllEvents} ->
            DcbOnly = [E || E <- AllEvents, is_dcb_event(E)],
            {ok, DcbOnly};
        {error, _} = Error ->
            Error
    end.

%% v1: only DCB-stream events count toward the consistency boundary.
%% The reckon-db backend's tag index is forward-only (per
%% PLAN_DCB_IMPLEMENTATION.md): only DCB events get /by_tag/ mirror
%% entries, so only DCB events are visible to the conditional-append
%% check. Filtering the runtime's read context to DCB-stream keeps
%% the cutoff calculation consistent with what the backend will see.
is_dcb_event(#{stream_id := ?DCB_STREAM_ID}) -> true;
is_dcb_event(#{<<"stream_id">> := ?DCB_STREAM_ID}) -> true;
is_dcb_event(_) -> false.

%% Highest version in the context (== global seq for DCB-stream events)
%% or -1 if empty.
compute_cutoff([]) -> -1;
compute_cutoff(Events) ->
    Versions = [event_version(E) || E <- Events],
    lists:max(Versions).

event_version(#{version := V}) when is_integer(V) -> V;
event_version(#{<<"version">> := V}) when is_integer(V) -> V;
event_version(_) -> -1.

retry_budget(Mod) ->
    case erlang:function_exported(Mod, retry_budget, 0) of
        true  -> Mod:retry_budget();
        false -> ?DEFAULT_RETRY_BUDGET
    end.

%% Exponential backoff capped, with jitter. AttemptsTaken is 0 on the
%% first retry, 1 on the second, etc. Sleep grows geometrically up to
%% ?DEFAULT_MAX_BACKOFF_MS; jitter is uniform over [1, BackoffMs].
backoff(Retries) ->
    AttemptsTaken = ?DEFAULT_RETRY_BUDGET - Retries,
    Base = ?DEFAULT_BASE_BACKOFF_MS * (1 bsl AttemptsTaken),
    Capped = erlang:min(Base, ?DEFAULT_MAX_BACKOFF_MS),
    Jitter = rand:uniform(Capped),
    timer:sleep(Jitter).
