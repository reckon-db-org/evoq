%% @doc One slow or retrying handler delays only its own events (evoq#30).
%%
%% The event router is one process, and it delivered to each handler in
%% turn with a call that waits for the handler's write, so a handler that
%% blocked, or slept out a {retry, DelayMs} backoff inside that call, held
%% up every handler and projection of every type on the node.
%%
%% Three handlers on one type, routed through the real router: the plain
%% one gets each event while the blocker is still holding event 1 and the
%% retrier is backing off; a strong-consistency wait on the plain one is
%% answered in that time; and the other two still get every event, in
%% order.
-module(evoq_delivery_isolation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TYPE, <<"isolation_delivered_v1">>).
-define(STORE, isolation_store).
-define(STREAM, <<"isolation-stream">>).
-define(BOUND_MS, 300).

isolation_test_() ->
    {setup, fun start/0, fun stop/1,
     fun(_) ->
         {timeout, 30, fun each_handler_at_its_own_pace/0}
     end}.

%% The handlers are started here, in the process they report to: eunit runs
%% setup in another one.
each_handler_at_its_own_pace() ->
    Handlers = [handler(Role) || Role <- [blocker, retrier, plain]],
    try delivered_at_own_pace(lists:last(Handlers))
    after [begin unlink(P), exit(P, shutdown) end || P <- Handlers]
    end.

delivered_at_own_pace(Plain) ->
    Waiter = evoq_consistency:open(?STORE, ?STREAM),
    try
        [route(N) || N <- [1, 2, 3]],
        %% The plain handler is not behind the other two.
        ?assertEqual([1, 2, 3], handled_within(plain, 3, ?BOUND_MS)),
        %% And its acknowledgment reaches a strong-consistency wait.
        ?assertEqual(ok, evoq_consistency:await(Waiter, [{Plain, 3}], 3,
                                                 #{first_version => 1,
                                                   timeout => ?BOUND_MS}))
    after
        evoq_consistency:close(Waiter)
    end,
    %% The other two get everything, each in order, at their own pace.
    Slow = evoq_isolation_probe_handler:block_ms() + 2000,
    ?assertEqual([1, 2, 3], handled_within(blocker, 3, Slow)),
    ?assertEqual([1, 1, 2, 3], handled_within(retrier, 4, Slow)).

route(N) ->
    Metadata = #{store_id => ?STORE, stream_id => ?STREAM,
                 version => N, stream_version => N},
    ok = evoq_event_router:route_event(#{event_type => ?TYPE, data => #{n => N}}, Metadata).

%% The events Role handled, in order, gathered until Count or the bound.
handled_within(Role, Count, BoundMs) ->
    Deadline = erlang:monotonic_time(millisecond) + BoundMs,
    gather(Role, Count, Deadline).

gather(_Role, 0, _Deadline) -> [];
gather(Role, Count, Deadline) ->
    Left = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive {handled, Role, N} -> [N | gather(Role, Count - 1, Deadline)]
    after Left -> []
    end.

start() ->
    {ok, _} = application:ensure_all_started(telemetry),
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, _} = evoq_event_type_registry:start_link(),
    {ok, _} = evoq_type_provider:start_link(),
    {ok, _} = evoq_event_router:start_link(),
    ok.

handler(Role) ->
    {ok, Pid} = evoq_event_handler:start_link(
                  evoq_isolation_probe_handler, #{role => Role, sink => self()},
                  #{identity => {evoq_isolation_probe_handler, Role}}),
    Pid.

stop(ok) ->
    Pids = [whereis(N) || N <- [evoq_event_router, evoq_type_provider, evoq_event_type_registry]],
    [begin unlink(P), exit(P, shutdown) end || P <- Pids, is_pid(P)],
    ok.
