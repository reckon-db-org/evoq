%% @doc A process manager instance's own messages reach its handle_info/2.
%%
%% evoq_pm_instance ignored every message a PM sent itself, so the one
%% thing a clock needs (a deadline that arrives as a message) had no home:
%% a per game clock could schedule its deadline and never be woken by it.
%% Messages now go to the PM module's optional handle_info/2, which may
%% update the PM state, dispatch commands, or stop the instance. A PM
%% without handle_info/2 that is sent a message logs a warning naming
%% itself and the message instead of losing it quietly. The atom `timeout'
%% stays evoq's own idle timer and is never forwarded.
-module(evoq_pm_instance_info_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

%% The deadline case: the message arrives, the PM sees it, and the state it
%% keeps changes. This is the shape a per game clock instance runs on.
a_scheduled_message_reaches_the_pm_test() ->
    Pid = start(evoq_info_probe_pm),
    erlang:send_after(10, Pid, {deadline, <<"game-1">>}),
    ?assertEqual({ok, #{deadline => <<"game-1">>}}, await_state(Pid, deadline)),
    stop(Pid).

%% The point of the hook: a clock deadline is not just observed, it
%% dispatches the command that records the flag.
a_message_can_dispatch_a_command_test() ->
    Pid = start(evoq_info_probe_pm),
    Commands = capture([[evoq, process_manager, command]], fun() ->
        Pid ! {deadline, <<"game-2">>},
        timer:sleep(100)
    end),
    ?assertEqual(1, length(Commands)),
    ?assertEqual(info_probe_flag, command_type(hd(Commands))),
    stop(Pid).

%% A message that carries no work must not be treated as one: the state
%% moves only where the PM moves it.
a_quiet_message_updates_the_pm_state_test() ->
    Pid = start(evoq_info_probe_pm),
    Pid ! {quiet, <<"nothing-to-do">>},
    ?assertEqual({ok, #{note => <<"nothing-to-do">>}}, await_state(Pid, note)),
    stop(Pid).

a_pm_can_stop_itself_from_handle_info_test() ->
    Pid = start(evoq_info_probe_pm),
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    Pid ! stop_please,
    ?assertEqual(normal, receive {'DOWN', MRef, process, Pid, R} -> R
                         after 1000 -> timeout end).

%% Silence is what hid the gap. A PM with no handle_info/2 is named.
a_message_to_a_pm_without_handle_info_is_named_test() ->
    Pid = start(evoq_info_probe_deaf_pm),
    ok = logger:add_handler(?MODULE, ?MODULE,
                            #{level => warning, config => #{pid => self()}}),
    try
        Pid ! {something, unexpected},
        ?assertEqual({evoq_info_probe_deaf_pm, {something, unexpected}},
                     receive {unhandled_info, H, M} -> {H, M} after 1000 -> none end),
        ?assert(is_process_alive(Pid))
    after
        _ = logger:remove_handler(?MODULE),
        stop(Pid)
    end.

%% `timeout' is evoq's idle timer, not a message for the PM: a PM that
%% exports handle_info/2 must not suddenly receive it.
the_idle_timeout_is_not_forwarded_to_the_pm_test() ->
    Pid = start(evoq_info_probe_pm),
    Pid ! timeout,
    timer:sleep(50),
    ?assertEqual({ok, #{}}, evoq_pm_instance:get_state(Pid)),
    stop(Pid).

%%====================================================================
%% Helpers
%%====================================================================

start(Module) ->
    {ok, Pid} = evoq_pm_instance:start_link(Module, <<"info-probe">>, #{}),
    Pid.

%% The PM state as the instance holds it, once it carries Key. The message
%% is asynchronous, so the assertion waits for the state rather than for a
%% fixed sleep whose length is a guess.
await_state(Pid, Key) ->
    await_state(Pid, Key, 50).

await_state(_Pid, _Key, 0) ->
    timeout;
await_state(Pid, Key, Tries) ->
    case evoq_pm_instance:get_state(Pid) of
        {ok, State} when is_map(State) ->
            case maps:is_key(Key, State) of
                true -> {ok, State};
                false -> timer:sleep(20), await_state(Pid, Key, Tries - 1)
            end;
        Other ->
            Other
    end.

stop(Pid) ->
    unlink(Pid),
    catch gen_server:stop(Pid).

capture(EventNames, Fun) ->
    {ok, _} = application:ensure_all_started(telemetry),
    Self = self(),
    Id = {?MODULE, make_ref()},
    ok = telemetry:attach_many(Id, EventNames,
                               fun(_Name, _M, Meta, _) -> Self ! {t, Meta} end, #{}),
    try Fun() after telemetry:detach(Id) end,
    collect([]).

collect(Acc) ->
    receive {t, M} -> collect([M | Acc])
    after 0 -> lists:reverse(Acc)
    end.

command_type(M) ->
    maps:get(command_type, M).

log(#{msg := {report, #{what := evoq_pm_has_no_handle_info,
                        pm := PM, message := Msg}}},
    #{config := #{pid := Pid}}) ->
    Pid ! {unhandled_info, PM, Msg};
log(_Event, _Config) ->
    ok.
