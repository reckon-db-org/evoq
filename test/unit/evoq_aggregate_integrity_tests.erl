%%% @doc Unit tests for evoq_aggregate's recognition of the
%%% {integrity_violation, _} error class from reckon-db 2.1.0.
%%%
%%% Integrity violations are terminal — they must NOT enter the
%%% rebuild-and-retry loop. The classifier locked down here is
%%% what the post-append error path and the rebuild-failure path
%%% both consult.
%%%
%%% Companion to evoq_aggregate_version_conflict_tests, which
%%% locks down the wrong_expected_version classifier.
%%% @end
-module(evoq_aggregate_integrity_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

%%====================================================================
%% is_integrity_violation/1 — shape classifier
%%====================================================================

recognises_storage_layer_violation_test() ->
    ?assert(evoq_aggregate:is_integrity_violation(
        {error, {integrity_violation, #{
            layer => storage,
            stream_id => <<"s">>,
            version => 0,
            kind => mac_mismatch
        }}})).

recognises_replay_layer_violation_test() ->
    ?assert(evoq_aggregate:is_integrity_violation(
        {error, {integrity_violation, #{
            layer => replay,
            kind => chain_mismatch
        }}})).

recognises_snapshot_layer_violation_test() ->
    ?assert(evoq_aggregate:is_integrity_violation(
        {error, {integrity_violation, #{
            layer => snapshot,
            kind => snapshot_anchor_mismatch
        }}})).

recognises_violation_with_empty_context_test() ->
    %% The context map is optional and may be absent — the classifier
    %% should not depend on any specific inner key.
    ?assert(evoq_aggregate:is_integrity_violation(
        {error, {integrity_violation, #{}}})).

%%====================================================================
%% Negative cases — must not over-match
%%====================================================================

rejects_wrong_version_error_test() ->
    %% wrong_expected_version is a SEPARATE error class with its own
    %% (retrying) behaviour. The two must not collapse together.
    ?assertNot(evoq_aggregate:is_integrity_violation(
        {error, wrong_expected_version})),
    ?assertNot(evoq_aggregate:is_integrity_violation(
        {error, {wrong_expected_version, 0, -1}})).

rejects_stream_not_found_test() ->
    ?assertNot(evoq_aggregate:is_integrity_violation(
        {error, {stream_not_found, <<"s">>}})).

rejects_bare_integrity_violation_test() ->
    %% The bare {integrity_violation, _} form is what
    %% reckon_gater_integrity returns internally. The public-facing
    %% reckon-db API wraps it as {error, _} — that's the form evoq
    %% receives and the form this classifier must match.
    ?assertNot(evoq_aggregate:is_integrity_violation(
        {integrity_violation, #{}})).

rejects_unrelated_error_with_integrity_violation_atom_test() ->
    %% Defensive: a tuple that happens to contain the atom
    %% `integrity_violation` somewhere else in its structure must
    %% not pass.
    ?assertNot(evoq_aggregate:is_integrity_violation(
        {error, {some_other_reason, integrity_violation}})).

rejects_success_tuple_test() ->
    ?assertNot(evoq_aggregate:is_integrity_violation({ok, 0})).

rejects_arbitrary_term_test() ->
    ?assertNot(evoq_aggregate:is_integrity_violation(undefined)),
    ?assertNot(evoq_aggregate:is_integrity_violation([])),
    ?assertNot(evoq_aggregate:is_integrity_violation(42)).

%%====================================================================
%% Schema — #evoq_event{} carries prev_event_hash
%%====================================================================

evoq_event_record_has_prev_event_hash_field_test() ->
    %% Record-info round-trip: confirms the field is declared. If a
    %% future change removes it (e.g. accidentally during a record
    %% reshape) this test fails at compile time.
    Fields = record_info(fields, evoq_event),
    ?assert(lists:member(prev_event_hash, Fields)).

evoq_event_prev_event_hash_defaults_to_undefined_test() ->
    %% Backward compatibility: callers constructing #evoq_event{}
    %% without the new field must continue to compile and run, and
    %% the field must default to `undefined` (the "legacy" marker).
    E = #evoq_event{event_id = <<"e">>, event_type = <<"x">>,
                    stream_id = <<"s">>, version = 0,
                    data = #{}, metadata = #{},
                    timestamp = 0, epoch_us = 0},
    ?assertEqual(undefined, E#evoq_event.prev_event_hash).

evoq_event_to_map_includes_prev_event_hash_test() ->
    %% Projections / process managers receive events as maps via
    %% evoq_event_store:event_to_map/1. The prev_event_hash field
    %% must survive that boundary so consumers can keylessly verify
    %% chain continuity if they choose to.
    Hash = <<1, 2, 3, 4, 5, 6, 7, 8,
             9, 10, 11, 12, 13, 14, 15, 16,
             17, 18, 19, 20, 21, 22, 23, 24,
             25, 26, 27, 28, 29, 30, 31, 32>>,
    E = #evoq_event{event_id = <<"e">>, event_type = <<"x">>,
                    stream_id = <<"s">>, version = 0,
                    data = #{}, metadata = #{},
                    timestamp = 0, epoch_us = 0,
                    prev_event_hash = Hash},
    Map = evoq_event_store:event_to_map(E),
    ?assertEqual(Hash, maps:get(prev_event_hash, Map)).

evoq_event_to_map_propagates_undefined_for_legacy_test() ->
    E = #evoq_event{event_id = <<"e">>, event_type = <<"x">>,
                    stream_id = <<"s">>, version = 0,
                    data = #{}, metadata = #{},
                    timestamp = 0, epoch_us = 0},
    Map = evoq_event_store:event_to_map(E),
    ?assertEqual(undefined, maps:get(prev_event_hash, Map)).
