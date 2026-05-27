%%% @doc PropEr properties for `evoq_decision_runtime`'s per-event
%%% filter algebra.
%%%
%%% Tests the client-side filter predicate that `read_context/2` uses
%%% to refine the broad `read_by_tags` result for compound filters.
%%% Properties verify the algebra obeys the laws a user would expect
%%% from a set-of-tags pattern matcher.
%%%
%%% Not concurrency-related — the headline serializability story is
%%% proven by reckon-db's `concurrent_uniqueness_only_one_wins` CT
%%% case. These properties cover algebraic correctness of the filter
%%% predicate, which is the half of evoq_decision the runtime can
%%% verify without a real Khepri.
%%% @end
-module(prop_evoq_decision_filter).

-include_lib("proper/include/proper.hrl").

-compile([export_all, nowarn_export_all]).

%%====================================================================
%% Generators
%%====================================================================

%% Tags from a small alphabet — encourages overlap, which is where
%% the algebra is interesting. Larger alphabets just produce trivial
%% (always-disjoint) cases.
tag() -> oneof([<<"a">>, <<"b">>, <<"c">>, <<"d">>, <<"e">>]).

tag_list() -> list(tag()).

unique_tag_list() -> ?LET(L, tag_list(), lists:usort(L)).

%% Recursive filter. Depth-bounded to keep test runs tractable.
filter() ->
    ?SIZED(Size, filter(Size)).

filter(0) ->
    oneof([{any_of, unique_tag_list()},
           {all_of, unique_tag_list()}]);
filter(Size) when Size > 0 ->
    SubSize = Size div 2,
    frequency([
        {3, {any_of, unique_tag_list()}},
        {3, {all_of, unique_tag_list()}},
        {2, {and_, list(filter(SubSize))}},
        {2, {or_,  list(filter(SubSize))}}
    ]).

%%====================================================================
%% Properties
%%====================================================================

%% Reordering tags in any_of doesn't change the match result.
prop_any_of_commutative() ->
    ?FORALL({EventTags, Tags},
            {unique_tag_list(), unique_tag_list()},
            begin
                Shuffled = shuffle(Tags),
                evoq_decision_runtime:match_filter(EventTags, {any_of, Tags}) =:=
                    evoq_decision_runtime:match_filter(EventTags, {any_of, Shuffled})
            end).

%% Same for all_of.
prop_all_of_commutative() ->
    ?FORALL({EventTags, Tags},
            {unique_tag_list(), unique_tag_list()},
            begin
                Shuffled = shuffle(Tags),
                evoq_decision_runtime:match_filter(EventTags, {all_of, Tags}) =:=
                    evoq_decision_runtime:match_filter(EventTags, {all_of, Shuffled})
            end).

%% Reordering sub-filters in or_/and_ doesn't change the match result.
prop_compound_commutative() ->
    ?FORALL({EventTags, Filters},
            {unique_tag_list(), list(filter(2))},
            begin
                Shuffled = shuffle(Filters),
                And1 = evoq_decision_runtime:match_filter(EventTags, {and_, Filters}),
                And2 = evoq_decision_runtime:match_filter(EventTags, {and_, Shuffled}),
                Or1  = evoq_decision_runtime:match_filter(EventTags, {or_, Filters}),
                Or2  = evoq_decision_runtime:match_filter(EventTags, {or_, Shuffled}),
                And1 =:= And2 andalso Or1 =:= Or2
            end).

%% De Morgan / containment: if event matches all_of(Tags) for non-empty
%% Tags, it must also match any_of(Tags).
prop_all_of_implies_any_of() ->
    ?FORALL({EventTags, Tags},
            {unique_tag_list(), non_empty(unique_tag_list())},
            begin
                case evoq_decision_runtime:match_filter(EventTags, {all_of, Tags}) of
                    true ->
                        evoq_decision_runtime:match_filter(EventTags, {any_of, Tags});
                    false ->
                        %% Implication: false → anything is fine
                        true
                end
            end).

%% Empty all_of and empty and_ match nothing.
prop_empty_compound_no_match() ->
    ?FORALL(EventTags, unique_tag_list(),
            begin
                not evoq_decision_runtime:match_filter(EventTags, {all_of, []}) andalso
                not evoq_decision_runtime:match_filter(EventTags, {and_, []})
            end).

%% Empty or_ matches nothing too.
prop_empty_or_no_match() ->
    ?FORALL(EventTags, unique_tag_list(),
            not evoq_decision_runtime:match_filter(EventTags, {or_, []})).

%% Single-element or_ acts as identity for its child filter.
prop_singleton_or_is_identity() ->
    ?FORALL({EventTags, Filter},
            {unique_tag_list(), filter()},
            evoq_decision_runtime:match_filter(EventTags, Filter) =:=
                evoq_decision_runtime:match_filter(EventTags, {or_, [Filter]})).

%% Single-element and_ acts as identity for its child filter.
prop_singleton_and_is_identity() ->
    ?FORALL({EventTags, Filter},
            {unique_tag_list(), filter()},
            evoq_decision_runtime:match_filter(EventTags, Filter) =:=
                evoq_decision_runtime:match_filter(EventTags, {and_, [Filter]})).

%% Disjoint event-tags and filter-tags: any_of must not match.
%% Phrased as an implication so PropEr doesn't starve on a too-tight
%% ?SUCHTHAT filter.
prop_disjoint_tags_no_match() ->
    ?FORALL({EventTags, Tags},
            {unique_tag_list(), non_empty(unique_tag_list())},
            case sets:is_disjoint(sets:from_list(EventTags),
                                  sets:from_list(Tags)) of
                true ->
                    not evoq_decision_runtime:match_filter(
                          EventTags, {any_of, Tags});
                false ->
                    true  %% precondition not met; trivially holds
            end).

%% Idempotence: any_of with duplicate tags matches the same as deduped.
prop_any_of_idempotent_in_tags() ->
    ?FORALL({EventTags, Tags},
            {unique_tag_list(), tag_list()},
            evoq_decision_runtime:match_filter(EventTags, {any_of, Tags}) =:=
                evoq_decision_runtime:match_filter(EventTags,
                                                    {any_of, lists:usort(Tags)})).

%% Self-test: an event ALWAYS matches a filter that asks for its own
%% tags (so long as the tag list is non-empty).
prop_event_matches_its_own_tags_any_of() ->
    ?FORALL(EventTags, non_empty(unique_tag_list()),
            evoq_decision_runtime:match_filter(EventTags, {any_of, EventTags})).

prop_event_matches_its_own_tags_all_of() ->
    ?FORALL(EventTags, non_empty(unique_tag_list()),
            evoq_decision_runtime:match_filter(EventTags, {all_of, EventTags})).

%%====================================================================
%% Helpers
%%====================================================================

shuffle(L) ->
    [E || {_, E} <- lists:sort([{rand:uniform(), El} || El <- L])].
