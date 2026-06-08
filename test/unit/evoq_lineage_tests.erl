-module(evoq_lineage_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Accessors
%%====================================================================

accessors_atom_keys_test() ->
    Meta = #{causation_id => <<"c1">>,
             correlation_id => <<"r1">>,
             conversation_id => <<"v1">>},
    ?assertEqual(<<"c1">>, evoq_lineage:causation_id(Meta)),
    ?assertEqual(<<"r1">>, evoq_lineage:correlation_id(Meta)),
    ?assertEqual(<<"v1">>, evoq_lineage:conversation_id(Meta)).

accessors_binary_keys_test() ->
    %% Events round-tripped through JSON storage carry binary keys.
    Meta = #{<<"causation_id">> => <<"c2">>,
             <<"correlation_id">> => <<"r2">>},
    ?assertEqual(<<"c2">>, evoq_lineage:causation_id(Meta)),
    ?assertEqual(<<"r2">>, evoq_lineage:correlation_id(Meta)),
    ?assertEqual(undefined, evoq_lineage:conversation_id(Meta)).

accessors_absent_and_non_map_test() ->
    ?assertEqual(undefined, evoq_lineage:causation_id(#{})),
    ?assertEqual(undefined, evoq_lineage:correlation_id(not_a_map)).

%%====================================================================
%% Canonical key binaries (must match reckon_shared.proto names)
%%====================================================================

key_binaries_test() ->
    ?assertEqual(<<"causation_id">>, evoq_lineage:causation_key()),
    ?assertEqual(<<"correlation_id">>, evoq_lineage:correlation_key()),
    ?assertEqual(<<"conversation_id">>, evoq_lineage:conversation_key()).

%%====================================================================
%% Query helpers (delegate to evoq_event_store:read_by_metadata)
%%====================================================================

query_helpers_test_() ->
    {setup,
     fun() -> meck:new(evoq_event_store, [passthrough]) end,
     fun(_) -> meck:unload(evoq_event_store) end,
     [fun get_effects_uses_causation_key/0,
      fun get_correlated_uses_correlation_key/0,
      fun get_conversation_uses_conversation_key/0]}.

get_effects_uses_causation_key() ->
    meck:expect(evoq_event_store, read_by_metadata,
                fun(_Store, Key, Val) -> {ok, [{Key, Val}]} end),
    ?assertEqual({ok, [{<<"causation_id">>, <<"evt-7">>}]},
                 evoq_lineage:get_effects(my_store, <<"evt-7">>)).

get_correlated_uses_correlation_key() ->
    meck:expect(evoq_event_store, read_by_metadata,
                fun(_Store, Key, Val) -> {ok, [{Key, Val}]} end),
    ?assertEqual({ok, [{<<"correlation_id">>, <<"saga-1">>}]},
                 evoq_lineage:get_correlated(my_store, <<"saga-1">>)).

get_conversation_uses_conversation_key() ->
    meck:expect(evoq_event_store, read_by_metadata,
                fun(_Store, Key, Val) -> {ok, [{Key, Val}]} end),
    ?assertEqual({ok, [{<<"conversation_id">>, <<"order-9">>}]},
                 evoq_lineage:get_conversation(my_store, <<"order-9">>)).
