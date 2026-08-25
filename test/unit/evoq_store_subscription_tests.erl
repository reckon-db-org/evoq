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

%%====================================================================
%% Sequence-based routing tests
%%====================================================================

%% @doc Verify that route_events_with_seq advances the sequence counter
%% and that the counter increases monotonically even across events
%% from different streams (which have overlapping stream-local versions).
route_events_with_seq_skips_unhandled_test() ->
    %% Start evoq_event_type_registry if not running
    ensure_routing_infrastructure(),

    %% No handlers registered — events should be skipped, seq unchanged
    Events = [
        make_event(<<"unregistered_type">>, <<"stream-a">>, 0),
        make_event(<<"unregistered_type">>, <<"stream-b">>, 0)
    ],
    FinalSeq = evoq_store_subscription:route_events_with_seq(Events, 0),
    ?assertEqual(0, FinalSeq).

route_events_with_seq_advances_for_handled_test() ->
    ensure_routing_infrastructure(),

    EventType = <<"test_handled_v1">>,
    %% Register a dummy handler
    Self = self(),
    ok = evoq_event_type_registry:register(EventType, Self),

    %% Two events from different streams, both with stream version 0
    Events = [
        make_event(EventType, <<"stream-a">>, 0),
        make_event(EventType, <<"stream-b">>, 0)
    ],
    FinalSeq = evoq_store_subscription:route_events_with_seq(Events, 0),
    ?assertEqual(2, FinalSeq),

    %% Clean up
    ok = evoq_event_type_registry:unregister(EventType, Self),
    drain_notifications().

route_events_with_seq_continues_from_previous_test() ->
    ensure_routing_infrastructure(),

    EventType = <<"test_continue_v1">>,
    Self = self(),
    ok = evoq_event_type_registry:register(EventType, Self),

    Events = [make_event(EventType, <<"stream-x">>, 0)],
    %% Start from seq 42
    FinalSeq = evoq_store_subscription:route_events_with_seq(Events, 42),
    ?assertEqual(43, FinalSeq),

    ok = evoq_event_type_registry:unregister(EventType, Self),
    drain_notifications().

%%====================================================================
%% Backfill filtering tests
%%
%% backfill_loop/5 itself needs a live store (evoq_event_store:
%% read_all_global/3) that this unit suite doesn't stand up -- see
%% test/integration/evoq_event_handler_SUITE.erl, which doesn't either;
%% no existing evoq test boots a real store. filter_by_type/2 is the one
%% genuinely new piece of logic that's pure, so it's what's tested here.
%% The mechanism itself is live-verified in hecate-whiteboard against a
%% real reckon-db store and a real umbrella boot-order race.
%%====================================================================

filter_by_type_keeps_only_matching_type_test() ->
    A1 = make_event(<<"type_a">>, <<"s-1">>, 0),
    B1 = make_event(<<"type_b">>, <<"s-1">>, 1),
    A2 = make_event(<<"type_a">>, <<"s-2">>, 0),
    ?assertEqual([A1, A2], evoq_store_subscription:filter_by_type([A1, B1, A2], <<"type_a">>)).

filter_by_type_preserves_order_test() ->
    Events = [make_event(<<"t">>, <<"s-1">>, N) || N <- lists:seq(0, 4)],
    ?assertEqual(Events, evoq_store_subscription:filter_by_type(Events, <<"t">>)).

filter_by_type_empty_when_nothing_matches_test() ->
    Events = [make_event(<<"type_a">>, <<"s-1">>, 0)],
    ?assertEqual([], evoq_store_subscription:filter_by_type(Events, <<"type_z">>)).

filter_by_type_skips_non_evoq_event_terms_test() ->
    A1 = make_event(<<"type_a">>, <<"s-1">>, 0),
    ?assertEqual([A1], evoq_store_subscription:filter_by_type([A1, not_an_event, {}], <<"type_a">>)).

%%====================================================================
%% Test Helpers
%%====================================================================

make_event(EventType, StreamId, Version) ->
    #evoq_event{
        event_id = iolist_to_binary([<<"evt-">>, StreamId, <<"-">>,
                                     integer_to_binary(Version)]),
        event_type = EventType,
        stream_id = StreamId,
        version = Version,
        data = #{},
        metadata = #{},
        tags = undefined,
        timestamp = 0,
        epoch_us = 0
    }.

ensure_routing_infrastructure() ->
    case whereis(evoq_event_type_registry) of
        undefined ->
            {ok, _} = evoq_event_type_registry:start_link();
        _ -> ok
    end,
    case whereis(evoq_type_provider) of
        undefined ->
            {ok, _} = evoq_type_provider:start_link();
        _ -> ok
    end,
    case whereis(evoq_event_router) of
        undefined ->
            {ok, _} = evoq_event_router:start_link();
        _ -> ok
    end,
    case whereis(evoq_pm_router) of
        undefined ->
            {ok, _} = evoq_pm_router:start_link();
        _ -> ok
    end,
    ok.

drain_notifications() ->
    receive _ -> drain_notifications()
    after 0 -> ok
    end.
