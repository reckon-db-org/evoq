%% @doc Integration tests for process managers (sagas).
%%
%% Tests:
%% - Process manager behavior
%% - PM router with correlation
%% - PM instance lifecycle
%% - Saga compensation
%%
%% @author rgfaber
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
    pm_lineage_two_hops_test/1,
    pm_lineage_keeps_a_correlation_the_pm_chose_test/1,
    a_compensating_pm_records_what_it_dispatched_test/1,
    pm_compensation_runs_on_failure_test/1
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
handle(State, #{event_type := <<"lineage_probe_v1">>}, _Metadata) ->
    %% A command as a process manager writes one: no lineage of its own.
    {ok, State, [evoq_command:new(probe_command, probe_aggregate, <<"probe-1">>, #{})]};
handle(State, #{event_type := <<"lineage_own_v1">>}, _Metadata) ->
    %% A PM that decides this is a conversation of its own says so on the
    %% command, before the instance stamps anything.
    Own = evoq_command:set_correlation_id(
            <<"own-conv">>,
            evoq_command:new(probe_command, probe_aggregate, <<"probe-1">>, #{})),
    {ok, State, [Own]};
handle(State, #{event_type := <<"compensation_probe_v1">>}, _Metadata) ->
    Charge = evoq_command:new(charge_payment, payment, <<"pay-1">>, #{}),
    Ship = evoq_command:new(ship_order, shipping, <<"ship-1">>, #{}),
    {ok, State, [Charge, Ship]};
handle(State, #{event_type := <<"compensation_probe_ok_v1">>}, _Metadata) ->
    Charge = evoq_command:new(charge_payment, payment, <<"pay-1">>, #{}),
    Ship = evoq_command:new(ship_order, shipping, <<"ship-1">>, #{}),
    {ok, State, [Charge, Ship]};
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
compensate(_State, #evoq_command{command_type = ship_order}) ->
    {ok, [evoq_command:new(issue_refund, payment, <<"pay-1">>, #{})]};
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
        {group, compensation_tests},
        {group, pm_lineage_tests}
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
            a_compensating_pm_records_what_it_dispatched_test,
            pm_compensation_runs_on_failure_test
        ]},
        {pm_lineage_tests, [sequence], [
            pm_lineage_two_hops_test,
            pm_lineage_keeps_a_correlation_the_pm_chose_test
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

    %% Verify instance was created. Routing is a cast, so wait for it, but
    %% an instance that never appears is a failure, not "async routing".
    {ok, Pid} = wait_for_instance(?MODULE, ProcessId, 50),
    ?assert(is_process_alive(Pid)),
    gen_server:stop(Pid),

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

    State1 = evoq_pm_compensation:record_command(Cmd1, State0),
    State2 = evoq_pm_compensation:record_command(Cmd2, State1),

    ExecutedCmds = evoq_pm_compensation:get_executed_commands(State2),
    ?assertEqual(2, length(ExecutedCmds)),
    ?assertEqual(Cmd2, hd(ExecutedCmds)),  %% Most recent first
    ok.

compensation_get_executed_test(_Config) ->
    %% Empty state
    ?assertEqual([], evoq_pm_compensation:get_executed_commands(#{})),

    %% Non-map state
    ?assertEqual([], evoq_pm_compensation:get_executed_commands(undefined)),
    ?assertEqual([], evoq_pm_compensation:get_executed_commands(some_atom)),

    %% State with commands
    Cmd = #evoq_command{
        command_id = <<"test-cmd">>,
        command_type = test,
        aggregate_type = test_agg,
        aggregate_id = <<"test-1">>,
        payload = #{}
    },
    State = #{executed_commands => [Cmd]},
    ?assertEqual([Cmd], evoq_pm_compensation:get_executed_commands(State)),
    ok.

wait_for_instance(PMModule, ProcessId, 0) ->
    evoq_pm_router:get_instance(PMModule, ProcessId);
wait_for_instance(PMModule, ProcessId, N) ->
    case evoq_pm_router:get_instance(PMModule, ProcessId) of
        {ok, _} = Found -> Found;
        {error, not_found} -> timer:sleep(20), wait_for_instance(PMModule, ProcessId, N - 1)
    end.

%%====================================================================
%% Lineage across a PM hop
%%====================================================================

%% A process manager is a responder: the command it issues belongs to the
%% conversation of the event that caused it. It did not before - the command
%% kept the correlation_id evoq_command:new/4,5 had minted and its
%% causation_id stayed undefined - so a chain aggregate -> event -> PM ->
%% command -> event started a new conversation at every hop and "how did I
%% get here?" had no answer (GY-AW Causation Id / Correlation Id).
pm_lineage_two_hops_test(_Config) ->
    Tab = capture_dispatch(fun(_Command) -> {ok, 1, []} end),
    try
        {ok, Hop1} = evoq_pm_instance_sup:start_instance(?MODULE, <<"lineage-1">>, #{}),
        Event1 = #{event_type => <<"lineage_probe_v1">>, event_id => <<"evt-1">>, data => #{}},
        {ok, _} = evoq_pm_instance:handle_event(Hop1, Event1,
                                                #{event_id => <<"evt-1">>,
                                                  correlation_id => <<"conv-1">>}),
        [First] = dispatched(Tab),
        ?assertEqual(<<"evt-1">>, First#evoq_command.causation_id),
        ?assertEqual(<<"conv-1">>, First#evoq_command.correlation_id),

        %% Hop 2. The event that command produced carries the command's id as
        %% its cause and the same correlation (evoq_aggregate:append_events/5),
        %% so a second PM must copy the conversation forward again.
        Event2Meta = #{event_id => <<"evt-2">>,
                       causation_id => First#evoq_command.command_id,
                       correlation_id => First#evoq_command.correlation_id},
        {ok, Hop2} = evoq_pm_instance_sup:start_instance(?MODULE, <<"lineage-2">>, #{}),
        Event2 = #{event_type => <<"lineage_probe_v1">>, event_id => <<"evt-2">>, data => #{}},
        {ok, _} = evoq_pm_instance:handle_event(Hop2, Event2, Event2Meta),
        [_FirstAgain, Second] = dispatched(Tab),
        ?assertEqual(<<"evt-2">>, Second#evoq_command.causation_id),
        ?assertEqual(<<"conv-1">>, Second#evoq_command.correlation_id)
    after
        stop_instance(<<"lineage-1">>),
        stop_instance(<<"lineage-2">>),
        release_capture(Tab)
    end,
    ok.

%% A PM that chose its own conversation keeps it: the explicit id on the
%% command wins over the event's. That is the opt-out from copy-forward.
pm_lineage_keeps_a_correlation_the_pm_chose_test(_Config) ->
    Tab = capture_dispatch(fun(_Command) -> {ok, 1, []} end),
    try
        {ok, Pid} = evoq_pm_instance_sup:start_instance(?MODULE, <<"lineage-own">>, #{}),
        Event = #{event_type => <<"lineage_own_v1">>, data => #{}},
        {ok, _} = evoq_pm_instance:handle_event(Pid, Event,
                                                #{event_id => <<"evt-own">>,
                                                  correlation_id => <<"conv-1">>}),
        [Command] = dispatched(Tab),
        ?assertEqual(<<"own-conv">>, Command#evoq_command.correlation_id),
        ?assertEqual(<<"evt-own">>, Command#evoq_command.causation_id)
    after
        stop_instance(<<"lineage-own">>),
        release_capture(Tab)
    end,
    ok.

%% A process manager that declared compensate/2 has each successful
%% dispatch recorded for it: that is what a compensation, or an operator,
%% can see there is to undo. A PM that never declared it gets no such key.
a_compensating_pm_records_what_it_dispatched_test(_Config) ->
    Tab = capture_dispatch(fun(_Command) -> {ok, 1, []} end),
    try
        {ok, Pid} = evoq_pm_instance_sup:start_instance(?MODULE, <<"record-1">>, #{}),
        Event = #{event_type => <<"compensation_probe_ok_v1">>, data => #{}},
        {ok, _} = evoq_pm_instance:handle_event(Pid, Event, #{event_id => <<"evt-r1">>}),
        {ok, PMState} = evoq_pm_instance:get_state(Pid),
        ?assertEqual([ship_order, charge_payment],
                     [C#evoq_command.command_type
                      || C <- evoq_pm_compensation:get_executed_commands(PMState)])
    after
        stop_instance(<<"record-1">>),
        release_capture(Tab)
    end,
    ok.

%%====================================================================
%% Compensation on a failed command
%%====================================================================

%% process_managers.md described a rollback that never happened: the
%% instance only logged a failed command and evoq_saga_compensation had no
%% caller. A saga that charges and then fails to ship refunds the charge.
pm_compensation_runs_on_failure_test(_Config) ->
    Tab = capture_dispatch(fun(Command) ->
        case Command#evoq_command.command_type of
            ship_order -> {error, declined};
            _ -> {ok, 1, []}
        end
    end),
    try
        {ok, Pid} = evoq_pm_instance_sup:start_instance(?MODULE, <<"comp-1">>, #{}),
        Event = #{event_type => <<"compensation_probe_v1">>, data => #{}},
        {ok, Results} = evoq_pm_instance:handle_event(Pid, Event,
                                                      #{event_id => <<"evt-c1">>,
                                                        correlation_id => <<"conv-comp">>}),

        [Charge, Ship, Refund] = dispatched(Tab),
        ?assertEqual(charge_payment, Charge#evoq_command.command_type),
        ?assertEqual(ship_order, Ship#evoq_command.command_type),
        ?assertEqual(issue_refund, Refund#evoq_command.command_type),

        %% The undo belongs to the same conversation as the commands it
        %% undoes: same cause, same correlation. It went out bare at first.
        ?assertEqual(<<"evt-c1">>, Refund#evoq_command.causation_id),
        ?assertEqual(<<"conv-comp">>, Refund#evoq_command.correlation_id),
        ?assertEqual(<<"conv-comp">>, Charge#evoq_command.correlation_id),

        %% Once compensated the transaction is over: what ran has been
        %% undone and the list starts again, rather than growing for the life
        %% of the process manager.
        {ok, PMState} = evoq_pm_instance:get_state(Pid),
        ?assertEqual([], evoq_pm_compensation:get_executed_commands(PMState)),

        %% The failure is reported, and the compensation's own result follows it.
        ?assertMatch([{ok, 1, []}, {error, declined}, {ok, 1, []}], Results)
    after
        stop_instance(<<"comp-1">>),
        release_capture(Tab)
    end,
    ok.

%%====================================================================
%% Dispatch capture
%%====================================================================

%% Stand in for the router: record every command a PM dispatches, in order,
%% and answer with Responder. Keeps these tests off a real event store while
%% still exercising the instance's own dispatch path end to end.
capture_dispatch(Responder) ->
    Tab = ets:new(evoq_pm_suite_dispatch, [public, duplicate_bag]),
    ok = meck:new(evoq_router, [passthrough]),
    ok = meck:expect(evoq_router, dispatch,
                     fun(Command) ->
                         ets:insert(Tab, {dispatch, erlang:unique_integer([monotonic]),
                                          Command}),
                         Responder(Command)
                     end),
    Tab.

dispatched(Tab) ->
    [Command || {dispatch, _, Command} <- lists:keysort(2, ets:tab2list(Tab))].

release_capture(Tab) ->
    meck:unload(evoq_router),
    ets:delete(Tab).

stop_instance(ProcessId) ->
    case evoq_pm_router:get_instance(?MODULE, ProcessId) of
        {ok, Pid} ->
            unlink(Pid),
            catch gen_server:stop(Pid),
            ok;
        {error, not_found} ->
            ok
    end.
