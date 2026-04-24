%%% @doc Unit tests for evoq_aggregate's wrong_expected_version handling.
%%%
%%% reckon-db's append returns `{error, {wrong_expected_version, Expected,
%%% Actual}}' (3-tuple) on optimistic concurrency conflicts; earlier
%%% iterations of reckon_gater returned `{error, {wrong_expected_version,
%%% Actual}}' (2-tuple). Evoq's handle_call used to pattern match
%%% `{error, wrong_expected_version}' only (plain atom), so the real
%%% 3-tuple form fell through to the generic error branch and the
%%% rebuild/retry machinery was dead code. These tests lock down the
%%% classifier so any future shape added to reckon-db forces us to
%%% update evoq too.
%%% @end
-module(evoq_aggregate_version_conflict_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% is_wrong_version_error/1 — shape classifier
%%====================================================================

recognises_plain_atom_test() ->
    ?assert(evoq_aggregate:is_wrong_version_error(
              {error, wrong_expected_version})).

recognises_actual_only_tuple_test() ->
    ?assert(evoq_aggregate:is_wrong_version_error(
              {error, {wrong_expected_version, -1}})).

recognises_expected_and_actual_tuple_test() ->
    ?assert(evoq_aggregate:is_wrong_version_error(
              {error, {wrong_expected_version, 0, -1}})).

rejects_unrelated_error_test() ->
    ?assertNot(evoq_aggregate:is_wrong_version_error(
                 {error, stream_not_found})).

rejects_success_tuple_test() ->
    ?assertNot(evoq_aggregate:is_wrong_version_error({ok, 0})).

rejects_bare_atom_test() ->
    ?assertNot(evoq_aggregate:is_wrong_version_error(wrong_expected_version)).

rejects_nested_unrelated_tuple_test() ->
    ?assertNot(evoq_aggregate:is_wrong_version_error(
                 {error, {some_other_reason, 1, 2}})).
