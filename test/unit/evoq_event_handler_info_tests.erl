%% @doc A handler's own messages reach its handle_info/2.
%%
%% evoq_event_handler's handle_info/2 used to drop every message, so a
%% handler that scheduled one to itself (a retry via send_after, which is
%% exactly what macula-realm's delegation publisher does) never saw it and
%% the retry silently never ran. Messages now go to the handler module's
%% optional handle_info/2; a handler without one that is sent a message
%% logs a warning naming itself and the message instead of losing it
%% quietly.
-module(evoq_event_handler_info_tests).

-include_lib("eunit/include/eunit.hrl").

-export([log/2]).

a_scheduled_message_reaches_the_handler_test() ->
    Pid = start(evoq_info_probe_handler),
    ok = evoq_event_handler:notify(Pid, <<"info_probe_v1">>,
                                   #{data => #{n => 7}}, #{}),
    timer:sleep(100),
    ?assertEqual([7], [N || {N, _} <- evoq_replay_probe:calls(info_received)]),
    ?assertEqual(7, maps:get(last_retry, handler_state(Pid))),
    stop(Pid).

a_handler_can_stop_itself_from_handle_info_test() ->
    Pid = start(evoq_info_probe_handler),
    MRef = erlang:monitor(process, Pid),
    unlink(Pid),
    Pid ! stop_please,
    ?assertEqual(normal, receive {'DOWN', MRef, process, Pid, R} -> R
                         after 1000 -> timeout end).

a_message_to_a_handler_without_handle_info_is_named_test() ->
    Pid = start(evoq_info_probe_deaf_handler),
    ok = logger:add_handler(?MODULE, ?MODULE,
                            #{level => warning, config => #{pid => self()}}),
    try
        Pid ! {something, unexpected},
        ?assertEqual({evoq_info_probe_deaf_handler, {something, unexpected}},
                     receive {unhandled_info, H, M} -> {H, M} after 1000 -> none end),
        ?assert(is_process_alive(Pid))
    after
        _ = logger:remove_handler(?MODULE),
        stop(Pid)
    end.

%%====================================================================
%% Helpers
%%====================================================================

start(Module) ->
    ok = evoq_replay_probe:reset(),
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link(), ok;
        _ -> ok
    end,
    {ok, Pid} = evoq_event_handler:start_link(Module, #{}),
    Pid.

%% The handler module's own state, as the gen_server holds it.
handler_state(Pid) ->
    element(3, sys:get_state(Pid)).

stop(Pid) ->
    unlink(Pid),
    catch gen_server:stop(Pid).

log(#{msg := {report, #{what := evoq_handler_has_no_handle_info,
                        handler := Handler, message := Msg}}},
    #{config := #{pid := Pid}}) ->
    Pid ! {unhandled_info, Handler, Msg};
log(_Event, _Config) ->
    ok.
