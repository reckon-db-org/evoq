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
        fun custom_retry_budget_honored/0
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
%% Helpers
%%====================================================================

dcb_event(Version) ->
    #{event_type => <<"some_event">>,
      stream_id => <<"_dcb">>,
      version => Version,
      data => #{},
      tags => [<<"x">>]}.

non_dcb_event(StreamId, Version) ->
    #{event_type => <<"agg_event">>,
      stream_id => StreamId,
      version => Version,
      data => #{},
      tags => [<<"x">>]}.
