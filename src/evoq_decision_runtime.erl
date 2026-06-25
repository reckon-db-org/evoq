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

%% Shared with evoq_decision_actor (Part B): one context-read
%% implementation, one cutoff rule. Returns the DCB-scoped context
%% events plus the seq cutoff (max version, or -1 for empty).
-export([load_context/2]).

%% Internal API — exposed for property-based testing. Subject to
%% change without semver guarantees.
-export([match_filter/2, collect_tags/1, collect_event_types/1]).

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
    %% Facade: a decision that returns a boundary_key opts into the
    %% per-node stateful actor (Part B); everything else runs the
    %% stateless optimistic loop (today's path, verbatim).
    case boundary_key(Mod, Command) of
        undefined ->
            Budget = retry_budget(Mod),
            dispatch_loop(Mod, StoreId, Command, Budget);
        Key when is_binary(Key) ->
            dispatch_stateful(Mod, StoreId, Command, Key)
    end.

%% @doc Read the DCB-scoped context for Filter and its seq cutoff.
%% Shared by the stateless loop and the stateful actor.
-spec load_context(atom(), evoq_decision:context_filter()) ->
    {ok, [map()], integer()} | {error, term()}.
load_context(StoreId, Filter) ->
    case read_context(StoreId, Filter) of
        {ok, Events} -> {ok, Events, compute_cutoff(Events)};
        {error, _} = Error -> Error
    end.

%%====================================================================
%% Internal
%%====================================================================

boundary_key(Mod, Command) ->
    case erlang:function_exported(Mod, boundary_key, 1) of
        true  -> Mod:boundary_key(Command);
        false -> undefined
    end.

dispatch_stateful(Mod, StoreId, Command, Key) ->
    case evoq_decision_registry:get_or_start(Mod, Key, StoreId) of
        {ok, Pid} ->
            gen_server:call(Pid, {decide, Command}, infinity);
        {error, _} = Error ->
            Error
    end.

dispatch_loop(_Mod, _StoreId, _Command, 0) ->
    {error, retry_budget_exhausted};
dispatch_loop(Mod, StoreId, Command, Retries) ->
    Filter = Mod:context(Command),
    case load_context(StoreId, Filter) of
        {error, _} = ReadError ->
            %% Surface read failures (e.g. an undeclared payload index)
            %% loudly rather than letting a bad decision through on an
            %% empty context. See graceful-degradation contract.
            ReadError;
        {ok, ContextEvents, Cutoff} ->
            case Mod:decide(ContextEvents, Command) of
                {error, _} = DecideError ->
                    DecideError;
                {ok, NewEvents} when is_list(NewEvents) ->
                    attempt_append(Mod, StoreId, Command, Filter, Cutoff, NewEvents, Retries)
            end
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
read_context(StoreId, {event_type, EventType}) when is_binary(EventType) ->
    %% Hit the [by_event_type] index directly (reckon-db 5.2.0+).
    dcb_filter(evoq_event_store:read_events_by_types(
                 StoreId, [EventType], ?DEFAULT_BATCH_SIZE));
read_context(StoreId, {payload_match, Key, Value} = Filter)
        when is_binary(Key), is_binary(Value) ->
    %% CCC: hit the {payload, Key} index directly. Fail loudly if the
    %% store does not declare it (graceful-degradation contract).
    read_payload(StoreId, Filter);
read_context(StoreId, {payload_hash_match, Keys, Values} = Filter)
        when is_list(Keys), is_list(Values) ->
    read_payload(StoreId, Filter);
read_context(StoreId, Filter) when is_tuple(Filter) ->
    %% Compound filter: read EVERY leaf fully via its own index, union
    %% the results, keep DCB-only, then refine client-side. Reading each
    %% leaf (rather than collecting tags and doing one union tag-read)
    %% is what makes {or_, [...]} mixing tag/event_type/payload leaves
    %% correct — no branch is inferred from a sibling.
    case read_all_leaf_events(StoreId, Filter) of
        {error, _} = Error ->
            Error;
        {ok, Events} ->
            Seen = lists:foldl(
                fun(E, Acc) -> maps:put(event_id(E), E, Acc) end,
                #{}, Events),
            DcbOnly = [E || E <- maps:values(Seen), is_dcb_event(E)],
            Matching = [E || E <- DcbOnly, event_matches_filter(E, Filter)],
            {ok, Matching}
    end.

read_filtered_to_dcb(StoreId, Tags, Match) ->
    dcb_filter(evoq_event_store:read_by_tags(StoreId, Tags, Match, ?DEFAULT_BATCH_SIZE)).

%% CCC payload read with up-front declared-index check. An undeclared
%% (or unintrospectable) index surfaces as
%% {error, {payload_index_unavailable, Filter}} so the decision fails
%% early instead of silently seeing an empty context.
read_payload(StoreId, {payload_match, Key, Value} = Filter) ->
    case payload_index_declared(StoreId, Key) of
        true ->
            dcb_filter(evoq_event_store:ccc_read_by_payload(
                         StoreId, Key, Value, ?DEFAULT_BATCH_SIZE));
        false ->
            {error, {payload_index_unavailable, Filter}}
    end;
read_payload(StoreId, {payload_hash_match, Keys, Values} = Filter) ->
    case payload_hash_index_declared(StoreId, Keys) of
        true ->
            dcb_filter(evoq_event_store:ccc_read_by_payload_hash(
                         StoreId, Keys, Values, ?DEFAULT_BATCH_SIZE));
        false ->
            {error, {payload_index_unavailable, Filter}}
    end.

payload_index_declared(StoreId, Key) ->
    case evoq_event_store:payload_indexes(StoreId) of
        {ok, Keys} -> lists:member(Key, Keys);
        {error, _} -> false
    end.

payload_hash_index_declared(StoreId, Keys) ->
    Wanted = lists:usort(Keys),
    case evoq_event_store:payload_hash_indexes(StoreId) of
        {ok, KeySets} ->
            lists:any(fun(Ks) -> lists:usort(Ks) =:= Wanted end, KeySets);
        {error, _} ->
            false
    end.

%% Keep only DCB-stream events from a read result, propagating errors.
dcb_filter({ok, Events}) ->
    {ok, [E || E <- Events, is_dcb_event(E)]};
dcb_filter({error, _} = Error) ->
    Error.

%% Read the union (by event_id) of every leaf's events under a compound
%% filter. Propagates the first error (e.g. payload_index_unavailable).
read_all_leaf_events(StoreId, {and_, Filters}) when is_list(Filters) ->
    read_leaves(StoreId, Filters);
read_all_leaf_events(StoreId, {or_, Filters}) when is_list(Filters) ->
    read_leaves(StoreId, Filters);
read_all_leaf_events(StoreId, Leaf) ->
    %% A leaf reached via recursion: read it through the same flat
    %% clauses, which already DCB-filter. Empty tag/type lists read
    %% nothing.
    case Leaf of
        {any_of, []} -> {ok, []};
        {all_of, []} -> {ok, []};
        _ -> read_context(StoreId, Leaf)
    end.

read_leaves(StoreId, Filters) ->
    lists:foldl(
        fun(_F, {error, _} = Err) -> Err;
           (F, {ok, Acc}) ->
               case read_all_leaf_events(StoreId, F) of
                   {ok, Events} -> {ok, Acc ++ Events};
                   {error, _} = Err -> Err
               end
        end, {ok, []}, Filters).

%% Walk a filter, returning the set (as a deduped list) of every tag
%% it references at any depth. Retained for property tests.
collect_tags({any_of, Tags}) when is_list(Tags) -> Tags;
collect_tags({all_of, Tags}) when is_list(Tags) -> Tags;
collect_tags({event_type, _}) -> [];
collect_tags({payload_match, _, _}) -> [];
collect_tags({payload_hash_match, _, _}) -> [];
collect_tags({and_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_tags/1, Filters));
collect_tags({or_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_tags/1, Filters)).

%% Walk a filter, returning the set (as a deduped list) of every
%% event_type it references at any depth. Retained for property tests.
collect_event_types({any_of, _}) -> [];
collect_event_types({all_of, _}) -> [];
collect_event_types({event_type, T}) when is_binary(T) -> [T];
collect_event_types({payload_match, _, _}) -> [];
collect_event_types({payload_hash_match, _, _}) -> [];
collect_event_types({and_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_event_types/1, Filters));
collect_event_types({or_, Filters}) when is_list(Filters) ->
    lists:usort(lists:flatmap(fun collect_event_types/1, Filters)).

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
%% Event map: event_type filter must read from the map, not the tag list.
match_filter(Event, {event_type, T}) when is_map(Event), is_binary(T) ->
    maps:get(event_type, Event,
        maps:get(<<"event_type">>, Event, undefined)) =:= T;
%% Event map: payload filters read opaque data fields, not tags.
match_filter(Event, {payload_match, K, V})
        when is_map(Event), is_binary(K) ->
    event_payload_value(Event, K) =:= V;
match_filter(Event, {payload_hash_match, Ks, Vs})
        when is_map(Event), is_list(Ks), is_list(Vs) ->
    length(Ks) =:= length(Vs) andalso
        lists:all(
            fun({K, V}) -> event_payload_value(Event, K) =:= V end,
            lists:zip(Ks, Vs));
match_filter(Tags, {any_of, Wanted}) when is_list(Tags), is_list(Wanted) ->
    lists:any(fun(T) -> lists:member(T, Tags) end, Wanted);
match_filter(Tags, {all_of, Wanted}) when is_list(Tags), is_list(Wanted) ->
    Wanted =/= [] andalso
        lists:all(fun(T) -> lists:member(T, Tags) end, Wanted);
%% Tag list: event_type / payload are not derivable from tags alone.
match_filter(_Tags, {event_type, _}) -> false;
match_filter(_Tags, {payload_match, _, _}) -> false;
match_filter(_Tags, {payload_hash_match, _, _}) -> false;
%% Compound over an event map: recurse with the MAP, not the tag list,
%% so event_type/payload leaves can read their fields. (Converting to
%% tags here would drop those dimensions — the closed or_-superset bug.)
match_filter(Event, {and_, Filters}) when is_map(Event), is_list(Filters) ->
    Filters =/= [] andalso
        lists:all(fun(F) -> match_filter(Event, F) end, Filters);
match_filter(Event, {or_, Filters}) when is_map(Event), is_list(Filters) ->
    lists:any(fun(F) -> match_filter(Event, F) end, Filters);
match_filter(Tags, {and_, Filters}) when is_list(Tags), is_list(Filters) ->
    Filters =/= [] andalso
        lists:all(fun(F) -> match_filter(Tags, F) end, Filters);
match_filter(Tags, {or_, Filters}) when is_list(Tags), is_list(Filters) ->
    lists:any(fun(F) -> match_filter(Tags, F) end, Filters);
%% Event map + tag leaf: fall back to the event's tag set.
match_filter(Event, Filter) when is_map(Event) ->
    match_filter(event_tags(Event), Filter).

event_tags(#{tags := T}) when is_list(T) -> T;
event_tags(#{<<"tags">> := T}) when is_list(T) -> T;
event_tags(_) -> [].

%% Look up a payload field value by (binary) key. evoq_event_store
%% flattens business data to the event's top level, so prefer that;
%% fall back to a nested data submap for events that kept it nested.
event_payload_value(Event, Key) ->
    case maps:find(Key, Event) of
        {ok, V} -> V;
        error ->
            Data = maps:get(data, Event, maps:get(<<"data">>, Event, #{})),
            payload_from_data(Data, Key)
    end.

payload_from_data(Data, Key) when is_map(Data) ->
    maps:get(Key, Data, undefined);
payload_from_data(_Data, _Key) ->
    undefined.

event_id(#{event_id := Id}) -> Id;
event_id(#{<<"event_id">> := Id}) -> Id;
event_id(E) when is_map(E) -> erlang:phash2(E).

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
