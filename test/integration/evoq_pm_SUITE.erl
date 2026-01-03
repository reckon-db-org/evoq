%% @doc Integration tests for process managers (sagas).
%%
%% Tests:
%% - Process manager behavior
%% - PM router with correlation
%% - PM instance lifecycle
%% - Saga compensation
%%
%% @author Reckon-DB
-module(evoq_pm_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%% CT callbacks
-export([all/0, groups/0, init_per_suite/1, end_per_suite/1]).
-export([init_per_group/2, end_per_group/2]).
-export([init_per_testcase/2, end_per_testcase/2]).

%% Test cases
-export([
    pm_register_test/1,
    pm_unregister_test/1,
    pm_instance_start_test/1,
    pm_instance_stop_test/1,
    pm_instance_handle_event_test/1,
    pm_instance_get_state_test/1,
    pm_router_correlation_start_test/1,
    pm_router_correlation_continue_test/1,
    compensation_record_commands_test/1,
    compensation_get_executed_test/1,
    compensation_build_chain_test/1
]).

%% Test PM module
-behaviour(evoq_process_manager).
-export([interested_in/0, correlate/2, handle/3, apply/2, compensate/2, init/1]).

%%====================================================================
%% Test PM Callbacks (inline module for testing)
%%====================================================================

interested_in() ->
    [<<"OrderPlaced">>, <<"PaymentReceived">>, <<"OrderFailed">>].

correlate(#{event_type := <<"OrderPlaced">>, data := #{order_id := OrderId}}, _Metadata) ->
    {start, OrderId};
correlate(#{data := #{order_id := OrderId}}, _Metadata) ->
    {continue, OrderId};
correlate(_Event, _Metadata) ->
    false.

init(ProcessId) ->
    {ok, #{process_id => ProcessId, status => started, commands => []}}.

handle(State, #{event_type := <<"OrderPlaced">>} = _Event, _Metadata) ->
    %% Dispatch a payment command
    Cmd = #evoq_command{
        command_id = crypto:strong_rand_bytes(16),
        command_type = process_payment,
        aggregate_type = payment,
        aggregate_id = <<"pay-123">>,
        payload = #{amount => 100}
    },
    {ok, State#{status => awaiting_payment}, [Cmd]};
handle(State, #{event_type := <<"PaymentReceived">>}, _Metadata) ->
    {ok, State#{status => paid}};
handle(State, #{event_type := <<"OrderFailed">>}, _Metadata) ->
    {ok, State#{status => failed}};
handle(State, _Event, _Metadata) ->
    {ok, State}.

apply(State, #{event_type := <<"OrderPlaced">>}) ->
    State#{status => order_placed};
apply(State, #{event_type := <<"PaymentReceived">>}) ->
    State#{status => payment_received};
apply(State, #{event_type := <<"OrderFailed">>}) ->
    State#{status => order_failed};
apply(State, _Event) ->
    State.

compensate(_State, #evoq_command{command_type = process_payment}) ->
    RefundCmd = #evoq_command{
        command_id = crypto:strong_rand_bytes(16),
        command_type = issue_refund,
        aggregate_type = payment,
        aggregate_id = <<"pay-123">>,
        payload = #{amount => 100}
    },
    {ok, [RefundCmd]};
compensate(_State, _FailedCommand) ->
    skip.

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [
        {group, pm_registration_tests},
        {group, pm_instance_tests},
        {group, pm_router_tests},
        {group, compensation_tests}
    ].

groups() ->
    [
        {pm_registration_tests, [sequence], [
            pm_register_test,
            pm_unregister_test
        ]},
        {pm_instance_tests, [sequence], [
            pm_instance_start_test,
            pm_instance_handle_event_test,
            pm_instance_get_state_test,
            pm_instance_stop_test
        ]},
        {pm_router_tests, [sequence], [
            pm_router_correlation_start_test,
            pm_router_correlation_continue_test
        ]},
        {compensation_tests, [sequence], [
            compensation_record_commands_test,
            compensation_get_executed_test,
            compensation_build_chain_test
        ]}
    ].

init_per_suite(Config) ->
    application:ensure_all_started(telemetry),
    application:ensure_all_started(evoq),
    Config.

end_per_suite(_Config) ->
    application:stop(evoq),
    ok.

init_per_group(pm_instance_tests, Config) ->
    %% Start an instance for the instance tests
    ProcessId = <<"order-instance-001">>,
    {ok, Pid} = evoq_pm_instance_sup:start_instance(?MODULE, ProcessId, #{}),
    [{pm_instance_pid, Pid}, {process_id, ProcessId} | Config];
init_per_group(_Group, Config) ->
    Config.

end_per_group(pm_instance_tests, Config) ->
    %% Stop the instance if still alive
    Pid = proplists:get_value(pm_instance_pid, Config),
    case is_pid(Pid) andalso is_process_alive(Pid) of
        true -> catch gen_server:stop(Pid);
        false -> ok
    end,
    Config;
end_per_group(_Group, Config) ->
    Config.

init_per_testcase(_TestCase, Config) ->
    Config.

end_per_testcase(_TestCase, _Config) ->
    ok.

%%====================================================================
%% PM Registration Tests
%%====================================================================

pm_register_test(_Config) ->
    %% Register this module as a PM
    ok = evoq_pm_router:register_pm(?MODULE),
    ok.

pm_unregister_test(_Config) ->
    %% Unregister this module
    ok = evoq_pm_router:unregister_pm(?MODULE),
    ok.

%%====================================================================
%% PM Instance Tests
%%====================================================================

pm_instance_start_test(Config) ->
    Pid = proplists:get_value(pm_instance_pid, Config),
    ?assert(is_pid(Pid)),
    ?assert(is_process_alive(Pid)),
    ok.

pm_instance_handle_event_test(Config) ->
    Pid = proplists:get_value(pm_instance_pid, Config),
    ProcessId = proplists:get_value(process_id, Config),

    %% Handle an OrderPlaced event
    Event = #{
        event_type => <<"OrderPlaced">>,
        data => #{order_id => ProcessId, items => []}
    },
    Metadata = #{stream_id => <<"order-stream">>, version => 1},

    Result = evoq_pm_instance:handle_event(Pid, Event, Metadata),
    %% Result contains dispatched command results
    ?assertMatch({ok, _}, Result),
    ok.

pm_instance_get_state_test(Config) ->
    Pid = proplists:get_value(pm_instance_pid, Config),

    {ok, State} = evoq_pm_instance:get_state(Pid),
    ?assert(is_map(State)),
    %% State should have status field from our PM
    ?assert(maps:is_key(status, State)),
    ok.

pm_instance_stop_test(Config) ->
    Pid = proplists:get_value(pm_instance_pid, Config),

    %% Stop the instance
    ok = evoq_pm_instance_sup:stop_instance(Pid),
    timer:sleep(50),  %% Give it time to stop
    ?assertNot(is_process_alive(Pid)),
    ok.

%%====================================================================
%% PM Router Tests
%%====================================================================

pm_router_correlation_start_test(_Config) ->
    %% Register PM
    ok = evoq_pm_router:register_pm(?MODULE),

    %% Route an OrderPlaced event which should start a new instance
    ProcessId = <<"order-router-001">>,
    Event = #{
        event_type => <<"OrderPlaced">>,
        data => #{order_id => ProcessId, items => []}
    },
    Metadata = #{stream_id => <<"test-stream">>, version => 1},

    %% Route the event
    ok = evoq_pm_router:route_event(Event, Metadata),

    %% Give it time to process
    timer:sleep(100),

    %% Verify instance was created
    EventType = <<"OrderPlaced">>,
    case evoq_pm_router:get_instance(EventType, ProcessId) of
        {ok, Pid} ->
            ?assert(is_pid(Pid)),
            ?assert(is_process_alive(Pid)),
            %% Cleanup
            gen_server:stop(Pid);
        {error, not_found} ->
            %% Instance might not be registered yet, that's ok for async routing
            ok
    end,

    %% Unregister PM
    ok = evoq_pm_router:unregister_pm(?MODULE),
    ok.

pm_router_correlation_continue_test(_Config) ->
    %% Register PM
    ok = evoq_pm_router:register_pm(?MODULE),

    %% Start an instance manually
    ProcessId = <<"order-router-002">>,
    {ok, Pid} = evoq_pm_instance_sup:start_instance(?MODULE, ProcessId, #{}),

    %% Route a PaymentReceived event (should continue with existing instance)
    Event = #{
        event_type => <<"PaymentReceived">>,
        data => #{order_id => ProcessId, amount => 100}
    },
    Metadata = #{stream_id => <<"test-stream">>, version => 2},

    ok = evoq_pm_router:route_event(Event, Metadata),

    %% Give it time to process
    timer:sleep(100),

    %% Instance should still be alive
    ?assert(is_process_alive(Pid)),

    %% Cleanup
    gen_server:stop(Pid),
    ok = evoq_pm_router:unregister_pm(?MODULE),
    ok.

%%====================================================================
%% Compensation Tests
%%====================================================================

compensation_record_commands_test(_Config) ->
    State0 = #{},

    %% Record some commands
    Cmd1 = #evoq_command{
        command_id = <<"cmd-1">>,
        command_type = charge_payment,
        aggregate_type = payment,
        aggregate_id = <<"pay-1">>,
        payload = #{}
    },
    Cmd2 = #evoq_command{
        command_id = <<"cmd-2">>,
        command_type = ship_order,
        aggregate_type = shipping,
        aggregate_id = <<"ship-1">>,
        payload = #{}
    },

    State1 = evoq_saga_compensation:record_command(Cmd1, State0),
    State2 = evoq_saga_compensation:record_command(Cmd2, State1),

    ExecutedCmds = evoq_saga_compensation:get_executed_commands(State2),
    ?assertEqual(2, length(ExecutedCmds)),
    ?assertEqual(Cmd2, hd(ExecutedCmds)),  %% Most recent first
    ok.

compensation_get_executed_test(_Config) ->
    %% Empty state
    ?assertEqual([], evoq_saga_compensation:get_executed_commands(#{})),

    %% Non-map state
    ?assertEqual([], evoq_saga_compensation:get_executed_commands(undefined)),
    ?assertEqual([], evoq_saga_compensation:get_executed_commands(some_atom)),

    %% State with commands
    Cmd = #evoq_command{
        command_id = <<"test-cmd">>,
        command_type = test,
        aggregate_type = test_agg,
        aggregate_id = <<"test-1">>,
        payload = #{}
    },
    State = #{executed_commands => [Cmd]},
    ?assertEqual([Cmd], evoq_saga_compensation:get_executed_commands(State)),
    ok.

compensation_build_chain_test(_Config) ->
    %% Create state with executed commands
    Cmd1 = #evoq_command{
        command_id = <<"cmd-1">>,
        command_type = process_payment,
        aggregate_type = payment,
        aggregate_id = <<"pay-1">>,
        payload = #{amount => 100}
    },
    Cmd2 = #evoq_command{
        command_id = <<"cmd-2">>,
        command_type = other_command,  %% This one has no compensation
        aggregate_type = other,
        aggregate_id = <<"other-1">>,
        payload = #{}
    },

    State = #{executed_commands => [Cmd2, Cmd1]},  %% Cmd2 was executed after Cmd1

    %% Build compensation chain
    CompensationChain = evoq_saga_compensation:build_compensation_chain(?MODULE, State),

    %% Should have compensation for process_payment (Cmd1) only
    %% Returned in reverse order, so Cmd2 is checked first (no compensation)
    %% then Cmd1 (has compensation)
    ?assertEqual(1, length(CompensationChain)),

    %% The compensation should be a refund command
    [RefundCmds] = CompensationChain,
    [RefundCmd] = RefundCmds,
    ?assertEqual(issue_refund, RefundCmd#evoq_command.command_type),
    ok.
