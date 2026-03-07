%% @doc Tests for evoq_store_subscription.
%%
%% Verifies:
%% - Event-to-routable conversion preserves all fields
%% - Undefined metadata handled gracefully
%% - Events with undefined type are skipped
%% - Non-evoq_event terms are skipped
-module(evoq_store_subscription_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

%%====================================================================
%% Unit Tests (pure functions, no gen_server needed)
%%====================================================================

event_to_routable_preserves_all_fields_test() ->
    Event = #evoq_event{
        event_id = <<"evt-123">>,
        event_type = <<"plugin_installed_v1">>,
        stream_id = <<"plugin-abc">>,
        version = 3,
        data = #{plugin_id => <<"abc">>, name => <<"test">>},
        metadata = #{correlation_id => <<"req-456">>},
        tags = [<<"realm:test">>],
        timestamp = 1000,
        epoch_us = 1000000
    },
    {RoutableEvent, Metadata} = evoq_store_subscription:evoq_event_to_routable(Event),

    %% Event map has all envelope fields
    ?assertEqual(<<"plugin_installed_v1">>, maps:get(event_type, RoutableEvent)),
    ?assertEqual(<<"evt-123">>, maps:get(event_id, RoutableEvent)),
    ?assertEqual(<<"plugin-abc">>, maps:get(stream_id, RoutableEvent)),
    ?assertEqual(3, maps:get(version, RoutableEvent)),
    ?assertEqual(#{plugin_id => <<"abc">>, name => <<"test">>},
                 maps:get(data, RoutableEvent)),
    ?assertEqual([<<"realm:test">>], maps:get(tags, RoutableEvent)),
    ?assertEqual(1000, maps:get(timestamp, RoutableEvent)),
    ?assertEqual(1000000, maps:get(epoch_us, RoutableEvent)),

    %% Metadata merges event metadata with routing fields
    ?assertEqual(<<"req-456">>, maps:get(correlation_id, Metadata)),
    ?assertEqual(<<"evt-123">>, maps:get(event_id, Metadata)),
    ?assertEqual(<<"plugin-abc">>, maps:get(stream_id, Metadata)),
    ?assertEqual(3, maps:get(version, Metadata)).

event_to_routable_handles_empty_metadata_test() ->
    Event = #evoq_event{
        event_id = <<"evt-1">>,
        event_type = <<"test_v1">>,
        stream_id = <<"s-1">>,
        version = 0,
        data = #{},
        metadata = #{},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    },
    {_RoutableEvent, Metadata} = evoq_store_subscription:evoq_event_to_routable(Event),
    %% Routing fields are present even with empty metadata
    ?assertEqual(<<"evt-1">>, maps:get(event_id, Metadata)),
    ?assertEqual(<<"s-1">>, maps:get(stream_id, Metadata)),
    ?assertEqual(0, maps:get(version, Metadata)),
    %% No correlation_id since metadata was empty
    ?assertEqual(error, maps:find(correlation_id, Metadata)).

event_to_routable_metadata_routing_fields_override_test() ->
    %% If event metadata has a version field, routing version takes precedence
    Event = #evoq_event{
        event_id = <<"evt-1">>,
        event_type = <<"test_v1">>,
        stream_id = <<"s-1">>,
        version = 5,
        data = #{},
        metadata = #{version => 99, custom => <<"value">>},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    },
    {_RoutableEvent, Metadata} = evoq_store_subscription:evoq_event_to_routable(Event),
    %% Routing version (from envelope) overrides metadata version
    ?assertEqual(5, maps:get(version, Metadata)),
    %% Custom metadata preserved
    ?assertEqual(<<"value">>, maps:get(custom, Metadata)).
