%% @doc One misbehaving process manager never silences the others (evoq#9).
%%
%% The router ran every process manager's correlate/2, and the call into
%% its instance, inside its own process with no try, and its registrations
%% lived only in its state. One function_clause in one correlate/2 (the
%% guide's basic process manager has no catch-all) restarted it empty, and
%% from then on every process manager on the node received nothing.
%%
%% Two process managers share the event types; the crashing one sorts
%% first, so a router that dies on it never reaches the steady one.
-module(evoq_pm_isolation_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1]).
-export([a_crash_in_correlate_reaches_only_its_own_process_manager_test/1,
         a_crash_in_handle_reaches_only_its_own_process_manager_test/1,
         registrations_survive_a_router_restart_test/1]).

-define(STEADY, evoq_pm_isolation_steady).
-define(CRASHING, evoq_pm_isolation_crashing).

all() ->
    [a_crash_in_correlate_reaches_only_its_own_process_manager_test,
     a_crash_in_handle_reaches_only_its_own_process_manager_test,
     registrations_survive_a_router_restart_test].

init_per_suite(Config) ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(evoq),
    ok = evoq_pm_router:register_pm(?CRASHING),
    ok = evoq_pm_router:register_pm(?STEADY),
    Config.

end_per_suite(_Config) ->
    application:stop(evoq),
    ok.

%% The event has no `id': the crasher's correlate/2 raises. The steady one
%% still handles it and the next one, the router is the same process, and
%% the crasher's event is kept as a dead letter.
a_crash_in_correlate_reaches_only_its_own_process_manager_test(_Config) ->
    sink(),
    Router = whereis(evoq_pm_router),
    route(<<"isolation_probed_v1">>, #{n => 1}),
    route(<<"isolation_probed_v1">>, #{n => 2}),
    ?assertEqual([1, 2], handled(2)),
    ?assertEqual(Router, whereis(evoq_pm_router)),
    ?assertMatch([_ | _], dead_letters(#{n => 1})).

%% The crasher's instance dies in handle/3, inside the router's call to it.
a_crash_in_handle_reaches_only_its_own_process_manager_test(_Config) ->
    sink(),
    Router = whereis(evoq_pm_router),
    route(<<"isolation_handler_broke_v1">>, #{id => <<"broke">>, n => 3}),
    route(<<"isolation_probed_v1">>, #{n => 4}),
    ?assertEqual([3, 4], handled(2)),
    ?assertEqual(Router, whereis(evoq_pm_router)),
    ?assertMatch([_ | _], dead_letters(#{id => <<"broke">>, n => 3})).

%% Whatever kills the router, the restarted one routes to both again.
registrations_survive_a_router_restart_test(_Config) ->
    sink(),
    Old = whereis(evoq_pm_router),
    exit(Old, kill),
    New = await_restart(Old, 50),
    route(<<"isolation_probed_v1">>, #{id => <<"after">>, n => 5}),
    ?assertEqual([5], handled(1)),
    ?assertEqual(New, whereis(evoq_pm_router)).

%%====================================================================

sink() ->
    persistent_term:put({?MODULE, sink}, self()).

route(Type, Data) ->
    ok = evoq_pm_router:route_event(#{event_type => Type, data => Data}, #{version => 0}).

handled(0) -> [];
handled(Count) ->
    receive {steady_handled, N} -> [N | handled(Count - 1)]
    after 2000 -> []
    end.

dead_letters(Data) ->
    [L || #evoq_dead_letter{handler_module = ?CRASHING, event = #{data := D}} = L
              <- evoq_dead_letter:list(), D =:= Data].

await_restart(Old, 0) ->
    ct:fail({router_never_restarted, Old});
await_restart(Old, N) ->
    case whereis(evoq_pm_router) of
        Pid when is_pid(Pid), Pid =/= Old -> Pid;
        _ -> timer:sleep(20), await_restart(Old, N - 1)
    end.
