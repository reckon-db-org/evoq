%%% @doc Unit tests for evoq_decision_runtime.
%%%
%%% meck-mocks evoq_event_store so the dispatch flow can be exercised
%%% without a real reckon-db backend.
%%%
%%% End-to-end serializability is proven by reckon-db's
%%% concurrent_uniqueness_only_one_wins CT case (P3.2). Here we cover:
%%% the dispatch lifecycle (context -> read -> decide -> append),
%%% retry-on-conflict, retry-budget exhaustion, cutoff computation,
%%% DCB-stream filtering, and error propagation.
%%% @end
-module(evoq_decision_runtime_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, decision_test_store).

%%====================================================================
%% Test decision modules
%%====================================================================
%% These tiny modules implement the evoq_decision behaviour for the
%% tests below. Defining them inline (not as separate compiled modules)
%% means we have to register them via meck.

%% Returns a context tied to a uniqueness tag, decides to append one
%% "registered" event.
test_decision_module_setup() ->
    meck:new(test_decision_uniqueness, [non_strict]),
    meck:expect(test_decision_uniqueness, context,
        fun(#{tag := Tag}) -> {any_of, [Tag]} end),
    meck:expect(test_decision_uniqueness, decide,
        fun(_ContextEvents, #{tag := Tag, value := V}) ->
            {ok, [#{event_type => <<"registered">>,
                    data => #{tag => Tag, value => V},
                    tags => [Tag]}]}
        end).

%% A decision that always fails its decide step.
test_decision_failing_setup() ->
    meck:new(test_decision_failing, [non_strict]),
    meck:expect(test_decision_failing, context,
        fun(_Cmd) -> {any_of, [<<"x">>]} end),
    meck:expect(test_decision_failing, decide,
        fun(_Ctx, _Cmd) -> {error, business_rule_violated} end).

%% A decision with a custom retry budget.
test_decision_short_budget_setup() ->
    meck:new(test_decision_short_budget, [non_strict]),
    meck:expect(test_decision_short_budget, context,
        fun(_Cmd) -> {any_of, [<<"x">>]} end),
    meck:expect(test_decision_short_budget, decide,
        fun(_Ctx, _Cmd) ->
            {ok, [#{event_type => <<"e">>, data => #{}, tags => [<<"x">>]}]}
        end),
    meck:expect(test_decision_short_budget, retry_budget,
        fun() -> 1 end).

%%====================================================================
%% Setup / Teardown
%%====================================================================

setup() ->
    application:set_env(evoq, event_store_adapter, mock_adapter),
    meck:new(evoq_event_store, [passthrough]),
    ok.

cleanup(_) ->
    application:unset_env(evoq, event_store_adapter),
    catch meck:unload(evoq_event_store),
    catch meck:unload(test_decision_uniqueness),
    catch meck:unload(test_decision_failing),
    catch meck:unload(test_decision_short_budget),
    catch meck:unload(test_decision_or),
    catch meck:unload(test_decision_and),
    catch meck:unload(test_decision_nested),
    catch meck:unload(test_decision_empty_or),
    catch meck:unload(test_decision_empty_and),
    ok.

%%====================================================================
%% Test runner
%%====================================================================

all_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun happy_path_empty_context/0,
        fun happy_path_with_context/0,
        fun decide_returns_error_propagates/0,
        fun context_changed_retries_then_succeeds/0,
        fun context_changed_exhausts_budget/0,
        fun backend_error_propagates/0,
        fun cutoff_is_minus_one_for_empty_read/0,
        fun cutoff_is_max_version_seen/0,
        fun non_dcb_events_filtered_from_context/0,
        fun custom_retry_budget_honored/0,
        fun or_filter_unions_subfilter_matches/0,
        fun and_filter_intersects_subfilter_matches/0,
        fun nested_compound_filter/0,
        fun empty_or_filter_yields_empty_context/0,
        fun empty_and_filter_yields_empty_context/0
    ]}.

%%====================================================================
%% Test cases
%%====================================================================

happy_path_empty_context() ->
    test_decision_module_setup(),
    %% Empty context (no matching events), append succeeds.
    meck:expect(evoq_event_store, read_by_tags,
        fun(_Store, _Tags, _Match, _Batch) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_Store, _Filter, Cutoff, _Events) ->
            ?assertEqual(-1, Cutoff),
            {ok, 0}
        end),
    Result = evoq_decision_runtime:dispatch(
               test_decision_uniqueness, ?STORE,
               #{tag => <<"email:alice">>, value => <<"alice@example.com">>}),
    ?assertMatch({ok, [#{event_type := <<"registered">>}]}, Result).

happy_path_with_context() ->
    test_decision_module_setup(),
    %% Context has 3 DCB events at versions 5, 7, 10. Cutoff = 10.
    DcbEvents = [dcb_event(5), dcb_event(7), dcb_event(10)],
    meck:expect(evoq_event_store, read_by_tags,
        fun(_S, _T, _M, _B) -> {ok, DcbEvents} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, Cutoff, _E) ->
            ?assertEqual(10, Cutoff),
            {ok, 11}
        end),
    {ok, _} = evoq_decision_runtime:dispatch(
                test_decision_uniqueness, ?STORE,
                #{tag => <<"x">>, value => 42}).

decide_returns_error_propagates() ->
    test_decision_failing_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    %% append must NOT be called when decide returns error.
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> ?assert(false), {ok, 0} end),
    ?assertEqual({error, business_rule_violated},
        evoq_decision_runtime:dispatch(
            test_decision_failing, ?STORE, #{})),
    %% append_if_no_tag_matches should NOT have been called.
    ?assertEqual(0, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

context_changed_retries_then_succeeds() ->
    test_decision_module_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    %% First call: conflict. Second call: success.
    Counter = counters:new(1, []),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, _C, _E) ->
            N = counters:get(Counter, 1),
            counters:add(Counter, 1, 1),
            case N of
                0 -> {error, {context_changed, 5}};
                _ -> {ok, 6}
            end
        end),
    Result = evoq_decision_runtime:dispatch(
               test_decision_uniqueness, ?STORE,
               #{tag => <<"x">>, value => 1}),
    ?assertMatch({ok, _}, Result),
    %% Verify retry happened: 2 append attempts, 2 reads.
    ?assertEqual(2, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')),
    ?assertEqual(2, meck:num_calls(evoq_event_store, read_by_tags, '_')).

context_changed_exhausts_budget() ->
    test_decision_module_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    %% Always conflict.
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, {context_changed, 99}} end),
    ?assertEqual({error, retry_budget_exhausted},
        evoq_decision_runtime:dispatch(
            test_decision_uniqueness, ?STORE,
            #{tag => <<"x">>, value => 1})),
    %% Default budget = 3 attempts total.
    ?assertEqual(3, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

backend_error_propagates() ->
    test_decision_module_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, some_backend_problem} end),
    ?assertEqual({error, some_backend_problem},
        evoq_decision_runtime:dispatch(
            test_decision_uniqueness, ?STORE,
            #{tag => <<"x">>, value => 1})),
    %% Non-conflict errors do NOT trigger retry.
    ?assertEqual(1, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

cutoff_is_minus_one_for_empty_read() ->
    test_decision_module_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    CutoffRef = make_ref(),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, Cutoff, _E) ->
            put(CutoffRef, Cutoff),
            {ok, 0}
        end),
    {ok, _} = evoq_decision_runtime:dispatch(
                test_decision_uniqueness, ?STORE,
                #{tag => <<"x">>, value => 1}),
    ?assertEqual(-1, get(CutoffRef)).

cutoff_is_max_version_seen() ->
    test_decision_module_setup(),
    DcbEvents = [dcb_event(3), dcb_event(17), dcb_event(8), dcb_event(1)],
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, DcbEvents} end),
    CutoffRef = make_ref(),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, Cutoff, _E) ->
            put(CutoffRef, Cutoff),
            {ok, 18}
        end),
    {ok, _} = evoq_decision_runtime:dispatch(
                test_decision_uniqueness, ?STORE,
                #{tag => <<"x">>, value => 1}),
    ?assertEqual(17, get(CutoffRef)).

non_dcb_events_filtered_from_context() ->
    test_decision_module_setup(),
    %% Read returns mixed: 2 aggregate-stream events at high versions
    %% (per their per-stream namespace), plus 1 DCB event at version 4.
    %% Only the DCB event must be counted toward the cutoff.
    Events = [
        non_dcb_event(<<"orders">>, 100),
        dcb_event(4),
        non_dcb_event(<<"users">>, 50)
    ],
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, Events} end),
    CutoffRef = make_ref(),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, Cutoff, _E) ->
            put(CutoffRef, Cutoff),
            {ok, 5}
        end),
    {ok, _} = evoq_decision_runtime:dispatch(
                test_decision_uniqueness, ?STORE,
                #{tag => <<"x">>, value => 1}),
    ?assertEqual(4, get(CutoffRef)),
    %% And the decide callback got ONLY the DCB event (not the
    %% aggregate events).
    DecideHistory =
        [Args || {_Pid, {_Mod, decide, Args}, _Ret}
                 <- meck:history(test_decision_uniqueness)],
    ?assertEqual(1, length(DecideHistory)),
    [[PassedEvents, _PassedCmd]] = DecideHistory,
    ?assertEqual(1, length(PassedEvents)),
    [PassedEvent] = PassedEvents,
    ?assertEqual(<<"_dcb">>, maps:get(stream_id, PassedEvent)).

custom_retry_budget_honored() ->
    test_decision_short_budget_setup(),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, {context_changed, 99}} end),
    %% retry_budget/0 returns 1 → exactly 1 attempt.
    ?assertEqual({error, retry_budget_exhausted},
        evoq_decision_runtime:dispatch(
            test_decision_short_budget, ?STORE, #{})),
    ?assertEqual(1, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

%%====================================================================
%% Compound filters
%%====================================================================

%% Returns an or_ filter over two tags. Decide returns no events
%% (just exercising the read path).
test_decision_or_setup() ->
    meck:new(test_decision_or, [non_strict]),
    meck:expect(test_decision_or, context,
        fun(_) -> {or_, [{any_of, [<<"a">>]}, {any_of, [<<"b">>]}]} end),
    meck:expect(test_decision_or, decide,
        fun(_Ctx, _Cmd) -> {ok, []} end).  %% empty append (will be no_events)

test_decision_and_setup() ->
    meck:new(test_decision_and, [non_strict]),
    meck:expect(test_decision_and, context,
        fun(_) -> {and_, [{any_of, [<<"a">>]}, {any_of, [<<"b">>]}]} end),
    meck:expect(test_decision_and, decide,
        fun(_Ctx, _Cmd) -> {ok, []} end).

test_decision_nested_setup() ->
    meck:new(test_decision_nested, [non_strict]),
    %% (any_of [a]) OR (all_of [b, c])
    meck:expect(test_decision_nested, context,
        fun(_) -> {or_, [{any_of, [<<"a">>]},
                         {all_of, [<<"b">>, <<"c">>]}]} end),
    meck:expect(test_decision_nested, decide,
        fun(_Ctx, _Cmd) -> {ok, []} end).

test_decision_empty_or_setup() ->
    meck:new(test_decision_empty_or, [non_strict]),
    meck:expect(test_decision_empty_or, context, fun(_) -> {or_, []} end),
    meck:expect(test_decision_empty_or, decide, fun(_, _) -> {ok, []} end).

test_decision_empty_and_setup() ->
    meck:new(test_decision_empty_and, [non_strict]),
    meck:expect(test_decision_empty_and, context, fun(_) -> {and_, []} end),
    meck:expect(test_decision_empty_and, decide, fun(_, _) -> {ok, []} end).

%% Helper: extract the ContextEvents passed to decide.
captured_decide_context(Mod) ->
    [Args || {_Pid, {_M, decide, Args}, _Ret} <- meck:history(Mod)].

or_filter_unions_subfilter_matches() ->
    test_decision_or_setup(),
    %% Backend returns events tagged a, b, or both, after the
    %% broad read_by_tags(any). The runtime should pass ALL of them
    %% to decide (any of {a} or any of {b} = events with either tag).
    EvA  = dcb_event_with(1, [<<"a">>]),
    EvB  = dcb_event_with(2, [<<"b">>]),
    EvAB = dcb_event_with(3, [<<"a">>, <<"b">>]),
    EvC  = dcb_event_with(4, [<<"c">>]),  %% should NOT match
    meck:expect(evoq_event_store, read_by_tags,
        fun(_Store, Tags, any, _Batch) ->
            %% Verify runtime asked for the UNION of tags.
            ?assertEqual(lists:usort([<<"a">>, <<"b">>]), lists:usort(Tags)),
            {ok, [EvA, EvB, EvAB, EvC]}
        end),
    %% decide returns no events to keep the test focused on read-path
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, no_events} end),
    _ = evoq_decision_runtime:dispatch(test_decision_or, ?STORE, #{}),
    [[Passed, _]] = captured_decide_context(test_decision_or),
    ?assertEqual([1, 2, 3], lists:sort([V || #{version := V} <- Passed])).

and_filter_intersects_subfilter_matches() ->
    test_decision_and_setup(),
    %% any_of([a]) AND any_of([b]) is per-event AND: events bearing
    %% both a and b. Backend returns events under broad any_of([a,b]);
    %% client-side filtering keeps only those with BOTH tags.
    EvA  = dcb_event_with(1, [<<"a">>]),
    EvB  = dcb_event_with(2, [<<"b">>]),
    EvAB = dcb_event_with(3, [<<"a">>, <<"b">>]),
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, [EvA, EvB, EvAB]} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, no_events} end),
    _ = evoq_decision_runtime:dispatch(test_decision_and, ?STORE, #{}),
    [[Passed, _]] = captured_decide_context(test_decision_and),
    %% Only EvAB has both tags.
    ?assertEqual([3], [V || #{version := V} <- Passed]).

nested_compound_filter() ->
    test_decision_nested_setup(),
    %% Filter: (any_of [a]) OR (all_of [b, c])
    %% Matches: events tagged with a OR events tagged with BOTH b and c.
    EvA   = dcb_event_with(1, [<<"a">>]),         %% matches first branch
    EvB   = dcb_event_with(2, [<<"b">>]),         %% no match (only b)
    EvBC  = dcb_event_with(3, [<<"b">>, <<"c">>]),%% matches second branch
    EvABC = dcb_event_with(4, [<<"a">>, <<"b">>, <<"c">>]), %% matches both
    EvD   = dcb_event_with(5, [<<"d">>]),         %% no match
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> {ok, [EvA, EvB, EvBC, EvABC, EvD]} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, no_events} end),
    _ = evoq_decision_runtime:dispatch(test_decision_nested, ?STORE, #{}),
    [[Passed, _]] = captured_decide_context(test_decision_nested),
    ?assertEqual([1, 3, 4], lists:sort([V || #{version := V} <- Passed])).

empty_or_filter_yields_empty_context() ->
    test_decision_empty_or_setup(),
    %% No tags referenced → no read should happen, context is []
    %% (and cutoff defaults to -1).
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> ct:fail(read_should_not_be_called) end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, no_events} end),
    _ = evoq_decision_runtime:dispatch(test_decision_empty_or, ?STORE, #{}),
    [[Passed, _]] = captured_decide_context(test_decision_empty_or),
    ?assertEqual([], Passed),
    ?assertEqual(0, meck:num_calls(evoq_event_store, read_by_tags, '_')).

empty_and_filter_yields_empty_context() ->
    test_decision_empty_and_setup(),
    %% Same logic as empty_or.
    meck:expect(evoq_event_store, read_by_tags,
        fun(_,_,_,_) -> ct:fail(read_should_not_be_called) end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, no_events} end),
    _ = evoq_decision_runtime:dispatch(test_decision_empty_and, ?STORE, #{}),
    [[Passed, _]] = captured_decide_context(test_decision_empty_and),
    ?assertEqual([], Passed).

%%====================================================================
%% Helpers
%%====================================================================

dcb_event(Version) ->
    dcb_event_with(Version, [<<"x">>]).

dcb_event_with(Version, Tags) ->
    #{event_type => <<"some_event">>,
      stream_id => <<"_dcb">>,
      version => Version,
      data => #{},
      tags => Tags}.

non_dcb_event(StreamId, Version) ->
    #{event_type => <<"agg_event">>,
      stream_id => StreamId,
      version => Version,
      data => #{},
      tags => [<<"x">>]}.
