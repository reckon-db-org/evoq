%% @doc A process-manager instance runs on one node (evoq#10).
%%
%% Instances are members of the pg scope evoq_pm_instances, and pg shows a
%% member on every connected node. get_instance/2 took the first member of
%% all of them, so with the same process manager on two nodes a router
%% could hand an event to the other node's instance (handled twice, once per
%% node, while the other node never started its own) and a {stop, Id} on
%% one node stopped the other's.
%%
%% A real peer node holds an instance for the same process manager and id.
%% The stand-in joins the group as an instance does and answers calls as an
%% instance does, telling the test what it was sent.
-module(evoq_pm_nodes_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

-export([all/0, init_per_suite/1, end_per_suite/1,
         init_per_testcase/2, end_per_testcase/2]).

-export([a_remote_instance_is_never_this_nodes_instance_test/1,
         an_event_routed_here_goes_to_this_nodes_own_instance_test/1,
         a_stop_here_leaves_the_other_nodes_instance_alone_test/1]).

%% Run on the peer
-export([start_standin/2]).

%% The process manager under test
-behaviour(evoq_process_manager).
-export([interested_in/0, correlate/2, handle/3, apply/2, init/1]).

-define(SCOPE, evoq_pm_instances).

%%====================================================================
%% Process manager
%%====================================================================

interested_in() -> [<<"node_probe_continued_v1">>, <<"node_probe_finished_v1">>].

correlate(#{event_type := <<"node_probe_continued_v1">>, data := #{id := Id}}, _) ->
    {continue, Id};
correlate(#{event_type := <<"node_probe_finished_v1">>, data := #{id := Id}}, _) ->
    {stop, Id}.

init(_ProcessId) -> {ok, #{seen => 0}}.

handle(#{seen := N} = State, _Event, _Metadata) -> {ok, State#{seen => N + 1}}.

apply(State, _Event) -> State.

%%====================================================================
%% CT callbacks
%%====================================================================

all() ->
    [a_remote_instance_is_never_this_nodes_instance_test,
     an_event_routed_here_goes_to_this_nodes_own_instance_test,
     a_stop_here_leaves_the_other_nodes_instance_alone_test].

init_per_suite(Config) ->
    ok = ensure_distributed(),
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(evoq),
    %% Not linked: init_per_suite runs in a process that ends with it.
    {ok, Peer, Node} = peer:start(#{name => peer:random_name(?MODULE),
                                         args => code_path_args()}),
    {ok, _} = erpc:call(Node, application, ensure_all_started, [telemetry]),
    {ok, _} = erpc:call(Node, pg, start, [?SCOPE]),
    ok = evoq_pm_router:register_pm(?MODULE),
    [{peer, Peer}, {peer_node, Node} | Config].

end_per_suite(Config) ->
    ok = evoq_pm_router:unregister_pm(?MODULE),
    peer:stop(?config(peer, Config)),
    application:stop(evoq),
    ok.

%% Each case gets its own process id and a stand-in for it on the peer.
init_per_testcase(Case, Config) ->
    Id = atom_to_binary(Case),
    Group = {pm_instance, ?MODULE, Id},
    Standin = erpc:call(?config(peer_node, Config), ?MODULE, start_standin,
                        [self(), Group]),
    ok = await_visible_here(Group, Standin, 50),
    [{id, Id}, {group, Group}, {standin, Standin} | Config].

end_per_testcase(_Case, Config) ->
    exit(?config(standin, Config), kill),
    [catch gen_server:stop(P) || P <- pg:get_local_members(?SCOPE, ?config(group, Config))],
    ok.

%%====================================================================
%% Cases
%%====================================================================

%% pg shows the peer's member here; it is still not this node's instance.
a_remote_instance_is_never_this_nodes_instance_test(Config) ->
    ?assertEqual([?config(standin, Config)], pg:get_members(?SCOPE, ?config(group, Config))),
    ?assertEqual({error, not_found}, evoq_pm_router:get_instance(?MODULE, ?config(id, Config))).

%% The event is handled here, by an instance this node starts, and the
%% peer's instance is sent nothing.
an_event_routed_here_goes_to_this_nodes_own_instance_test(Config) ->
    ok = evoq_pm_router:route_event(event(<<"node_probe_continued_v1">>, Config), #{version => 0}),
    [Local] = await_local_instance(?config(group, Config), 50),
    ?assertEqual(node(), node(Local)),
    ?assertEqual({ok, #{seen => 1}}, evoq_pm_instance:get_state(Local)),
    nothing_reached_the_standin().

%% A stop routed here has no instance here to stop; the peer's lives on.
a_stop_here_leaves_the_other_nodes_instance_alone_test(Config) ->
    ok = evoq_pm_router:route_event(event(<<"node_probe_finished_v1">>, Config), #{version => 0}),
    _ = sys:get_state(evoq_pm_router),
    nothing_reached_the_standin(),
    Standin = ?config(standin, Config),
    ?assert(erpc:call(node(Standin), erlang, is_process_alive, [Standin])).

%%====================================================================
%% The stand-in, on the peer
%%====================================================================

start_standin(Test, Group) ->
    Pid = spawn(fun() -> standin(Test) end),
    ok = pg:join(?SCOPE, Group, Pid),
    Pid.

%% It answers calls and stops as an instance would, so a wrongly routed
%% event or stop shows up as a message to the test, never as a hang.
standin(Test) ->
    receive
        {'$gen_call', From, Request} ->
            Test ! {standin_got, Request},
            gen:reply(From, ok),
            standin(Test);
        {system, From, Request} ->
            Test ! {standin_got, {system, Request}},
            gen:reply(From, ok),
            standin(Test)
    end.

%%====================================================================
%% Helpers
%%====================================================================

event(Type, Config) ->
    #{event_type => Type, data => #{id => ?config(id, Config)}}.

nothing_reached_the_standin() ->
    receive {standin_got, Request} -> ct:fail({routed_to_the_other_node, Request})
    after 500 -> ok
    end.

await_visible_here(_Group, Standin, 0) ->
    ct:fail({peer_member_never_visible, Standin});
await_visible_here(Group, Standin, N) ->
    case lists:member(Standin, pg:get_members(?SCOPE, Group)) of
        true -> ok;
        false -> timer:sleep(20), await_visible_here(Group, Standin, N - 1)
    end.

await_local_instance(Group, 0) ->
    ct:fail({no_local_instance, Group});
await_local_instance(Group, N) ->
    case pg:get_local_members(?SCOPE, Group) of
        [] -> timer:sleep(20), await_local_instance(Group, N - 1);
        Local -> Local
    end.

%% pg needs a distributed node; rebar3 ct runs a plain one unless told.
ensure_distributed() ->
    case node() of
        nonode@nohost ->
            _ = os:cmd("epmd -daemon"),
            {ok, _} = net_kernel:start(evoq_pm_nodes_origin, #{name_domain => shortnames}),
            ok;
        _ ->
            ok
    end.

code_path_args() ->
    lists:append([["-pa", Dir] || Dir <- code:get_path()]).
