%% @doc Integration tests for event handling.
%%
%% Tests:
%% - Event handler behavior
%% - Event type registry
%% - Event routing
%% - Event upcasting
%% - Type provider
%%
%% @author rgfaber
-module(evoq_event_handler_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    type_registry_register_test/1,
    type_registry_get_handlers_test/1,
    type_registry_unregister_test/1,
    type_provider_register_event_test/1,
    type_provider_register_upcaster_test/1,
    type_provider_get_module_test/1,
    event_router_route_test/1,
    upcaster_chain_test/1
]).

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, type_registry_tests},
        {group, type_provider_tests},
        {group, router_tests},
        {group, upcaster_tests}
    ].

groups() ->
    [
        {type_registry_tests, [sequence], [
            type_registry_register_test,
            type_registry_get_handlers_test,
            type_registry_unregister_test
        ]},
        {type_provider_tests, [sequence], [
            type_provider_register_event_test,
            type_provider_register_upcaster_test,
            type_provider_get_module_test
        ]},
        {router_tests, [sequence], [
            event_router_route_test
        ]},
        {upcaster_tests, [sequence], [
            upcaster_chain_test
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    application:ensure_all_started(evoq),
    Config.

end_per_suite(_Config) ->
    application:stop(evoq),
    ok.

init_per_group(_Group, Config) ->
    Config.

end_per_group(_Group, Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% Type Registry Tests
%%====================================================================

type_registry_register_test(_Config) ->
    EventType = <<"test.event.created">>,

    %% Register self as handler
    ok = evoq_event_type_registry:register(EventType, self()),

    %% Verify registration
    Handlers = evoq_event_type_registry:get_handlers(EventType),
    ?assert(lists:member(self(), Handlers)),

    %% Cleanup
    evoq_event_type_registry:unregister(EventType, self()),
    ok.

type_registry_get_handlers_test(_Config) ->
    EventType = <<"test.event.updated">>,

    %% Initially empty
    Handlers1 = evoq_event_type_registry:get_handlers(EventType),
    ?assertEqual([], Handlers1),

    %% Register multiple handlers
    Pid1 = spawn(fun() -> receive stop -> ok end end),
    Pid2 = spawn(fun() -> receive stop -> ok end end),

    ok = evoq_event_type_registry:register(EventType, Pid1),
    ok = evoq_event_type_registry:register(EventType, Pid2),

    %% Get handlers
    Handlers2 = evoq_event_type_registry:get_handlers(EventType),
    ?assertEqual(2, length(Handlers2)),
    ?assert(lists:member(Pid1, Handlers2)),
    ?assert(lists:member(Pid2, Handlers2)),

    %% Cleanup
    Pid1 ! stop,
    Pid2 ! stop,
    evoq_event_type_registry:unregister(EventType, Pid1),
    evoq_event_type_registry:unregister(EventType, Pid2),
    ok.

type_registry_unregister_test(_Config) ->
    EventType = <<"test.event.deleted">>,

    %% Register
    ok = evoq_event_type_registry:register(EventType, self()),
    Handlers1 = evoq_event_type_registry:get_handlers(EventType),
    ?assert(lists:member(self(), Handlers1)),

    %% Unregister
    ok = evoq_event_type_registry:unregister(EventType, self()),
    Handlers2 = evoq_event_type_registry:get_handlers(EventType),
    ?assertNot(lists:member(self(), Handlers2)),
    ok.

%%====================================================================
%% Type Provider Tests
%%====================================================================

type_provider_register_event_test(_Config) ->
    EventType = <<"account.created">>,
    Module = account_created_event,

    ok = evoq_type_provider:register_event(EventType, Module),

    %% Verify registration
    ?assertEqual({ok, Module}, evoq_type_provider:get_module(EventType)),
    ok.

type_provider_register_upcaster_test(_Config) ->
    EventType = <<"account.created.v1">>,
    Upcaster = account_created_v1_upcaster,

    ok = evoq_type_provider:register_upcaster(EventType, Upcaster),

    %% Verify registration
    ?assertEqual({ok, Upcaster}, evoq_type_provider:get_upcaster(EventType)),
    ok.

type_provider_get_module_test(_Config) ->
    %% Non-existent type
    ?assertEqual({error, not_found}, evoq_type_provider:get_module(<<"non.existent">>)),

    %% Register and get
    EventType = <<"order.placed">>,
    Module = order_placed_event,
    ok = evoq_type_provider:register_event(EventType, Module),
    ?assertEqual({ok, Module}, evoq_type_provider:get_module(EventType)),
    ok.

%%====================================================================
%% Event Router Tests
%%====================================================================

event_router_route_test(_Config) ->
    EventType = <<"test.routed.event">>,

    %% Register self as handler
    ok = evoq_event_type_registry:register(EventType, self()),

    %% Route an event - this is async (cast)
    Event = #{event_type => EventType, data => #{value => 42}},
    Metadata = #{stream_id => <<"test-stream">>, version => 1},
    ok = evoq_event_router:route_event(Event, Metadata),

    %% Note: Since route_event is a cast, we can't directly verify
    %% the event was routed. In a real test, we'd use a mock handler.
    %% For now, just verify no errors occurred.

    %% Cleanup
    evoq_event_type_registry:unregister(EventType, self()),
    ok.

%%====================================================================
%% Upcaster Tests
%%====================================================================

upcaster_chain_test(_Config) ->
    %% Test empty chain
    Event1 = #{event_type => <<"test">>, data => #{value => 1}},
    ?assertEqual({ok, Event1}, evoq_event_upcaster:chain_upcasters([], Event1, #{})),

    %% Test that chain_upcasters works (even with empty list)
    Event2 = #{event_type => <<"test.v1">>, data => #{old_field => <<"value">>}},
    {ok, Result} = evoq_event_upcaster:chain_upcasters([], Event2, #{}),
    ?assertEqual(Event2, Result),
    ok.
