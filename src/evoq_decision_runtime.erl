%%% @doc Runtime for the evoq_decision behaviour.
%%%
%%% Wires the user-facing callback contract (context/1, decide/2)
%%% to the event-store adapter's conditional-append primitive
%%% (append_if_no_tag_matches/4):
%%%
%%%   1. Call Mod:context(Command) to get the tag-filter.
%%%   2. Read the context events matching that filter (DCB-stream only).
%%%   3. Compute the seq cutoff from the highest version seen
%%%      (or -1 for "saw nothing").
%%%   4. Call Mod:decide(ContextEvents, Command).
%%%   5. Conditionally append the resulting events.
%%%   6. On {error, {context_changed, _}}, sleep with bounded
%%%      exponential backoff + jitter, then retry from step 2. Retries
%%%      are bounded by Mod:retry_budget/0 (default 3).
%%%
%%% Returns:
%%%   - {ok, [Event]}: events appended; commit produced.
%%%   - {error, retry_budget_exhausted}: too many context_changed
%%%     conflicts. Caller decides whether to escalate or give up.
%%%   - {error, Reason}: domain error from decide/2 or backend
%%%     error from the append path. Propagated as-is.
%%% @end
-module(evoq_decision_runtime).

-export([dispatch/3]).

%% Internal API — exposed for property-based testing. Subject to
%% change without semver guarantees.
-export([match_filter/2, collect_tags/1]).

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

%% Read context events matching Filter.
%%
%% Flat filters (any_of/all_of) hit read_by_tags directly with the
%% appropriate match mode.
%%
%% Compound filters (and_/or_) require client-side combination:
%%   1. Walk the filter tree, collect all tags it references (set union).
%%   2. Read events tagged with ANY of those tags (broadest possible).
%%   3. Filter client-side, retaining only events whose tag-set actually
%%      satisfies the compound predicate.
%%
%% All paths filter to DCB-stream events only — same v1 limitation as
%% before: mixed-mode (aggregate streams + DCB sharing tags) is
%% unsupported by evoq_decision; the cutoff calculation needs the
%% consistency check's view of events.
read_context(StoreId, {any_of, Tags}) when is_list(Tags) ->
    read_filtered_to_dcb(StoreId, Tags, any);
read_context(StoreId, {all_of, Tags}) when is_list(Tags) ->
    read_filtered_to_dcb(StoreId, Tags, all);
read_context(StoreId, Filter) when is_tuple(Filter) ->
    %% Compound filter: pull a superset and refine client-side.
    case collect_tags(Filter) of
        [] ->
            %% Vacuous compound filter (e.g., {or_, []}). No tags to
            %% read, no events to consider.
            {ok, []};
        AllTags ->
            case evoq_event_store:read_by_tags(
                   StoreId, AllTags, any, ?DEFAULT_BATCH_SIZE) of
                {ok, Events} ->
                    DcbOnly = [E || E <- Events, is_dcb_event(E)],
                    Matching = [E || E <- DcbOnly,
                                     event_matches_filter(E, Filter)],
                    {ok, Matching};
                {error, _} = Error ->
                    Error
            end
    end.

read_filtered_to_dcb(StoreId, Tags, Match) ->
    case evoq_event_store:read_by_tags(StoreId, Tags, Match, ?DEFAULT_BATCH_SIZE) of
        {ok, AllEvents} ->
            DcbOnly = [E || E <- AllEvents, is_dcb_event(E)],
            {ok, DcbOnly};
        {error, _} = Error ->
            Error
    end.

%% Walk a filter, returning the set (as a deduped list) of every tag
%% it references at any depth.
collect_tags({any_of, Tags}) when is_list(Tags) -> Tags;
collect_tags({all_of, Tags}) when is_list(Tags) -> Tags;
collect_tags({and_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_tags/1, Filters));
collect_tags({or_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_tags/1, Filters)).

%% Does an event's tag-set satisfy the filter? Per-event semantics
%% matches the backend's reckon_db_dcb_filter:match_seqs/2.
event_matches_filter(Event, Filter) ->
    match_filter(Event, Filter).

%% @doc Public-for-testing version of the per-event filter predicate.
%% Accepts either an event map (using maps:get(tags, ...)) or a raw
%% tag list — handy for property-based tests that don't want to build
%% full event maps. Subject to change without semver guarantees.
-spec match_filter(Event | Tags, evoq_decision:context_filter()) -> boolean()
    when Event :: map(), Tags :: [binary()].
match_filter(Tags, {any_of, Wanted}) when is_list(Tags), is_list(Wanted) ->
    lists:any(fun(T) -> lists:member(T, Tags) end, Wanted);
match_filter(Tags, {all_of, Wanted}) when is_list(Tags), is_list(Wanted) ->
    Wanted =/= [] andalso
        lists:all(fun(T) -> lists:member(T, Tags) end, Wanted);
match_filter(Tags, {and_, Filters}) when is_list(Tags), is_list(Filters) ->
    Filters =/= [] andalso
        lists:all(fun(F) -> match_filter(Tags, F) end, Filters);
match_filter(Tags, {or_, Filters}) when is_list(Tags), is_list(Filters) ->
    lists:any(fun(F) -> match_filter(Tags, F) end, Filters);
match_filter(Event, Filter) when is_map(Event) ->
    match_filter(event_tags(Event), Filter).

event_tags(#{tags := T}) when is_list(T) -> T;
event_tags(#{<<"tags">> := T}) when is_list(T) -> T;
event_tags(_) -> [].

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
