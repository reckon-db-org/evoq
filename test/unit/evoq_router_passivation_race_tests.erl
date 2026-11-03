%%% @doc A command that races its aggregate's passivation is dispatched again
%%% (evoq#57).
%%%
%%% `execute_on_aggregate_with_state/5' takes a pid from
%%% `evoq_aggregate_registry:get_or_start/3' and then calls it. The lookup only
%%% says the process was alive a moment earlier: an aggregate whose lifespan
%%% fires in that window stops with reason `normal', which
%%% `evoq_aggregate:called/2' turns into `{error, not_running}'. The command
%%% never reached `handle_call', so nothing was appended and nothing in the
%%% domain said no -- it is a timing race, not an answer, and it used to be
%%% reported as a failure all the same. Every consumer then had to write its
%%% own retry; macula-realm did, after the hourly endorsement sweep paged
%%% operators on work that had never run.
%%%
%%% The window cannot be opened from outside a dispatch, so the race test opens
%%% it at the one seam the router has: `evoq_aggregate_registry:get_or_start/3'
%%% answers once with an aggregate that has already passivated (a real one,
%%% stopped the way passivation stops it) and then passes through to the real
%%% registry. What the router must do with that answer is the subject: ask
%%% again, execute on the fresh aggregate, and append exactly once.
%%%
%%% The other two tests hold the other side: `shutdown' and
%%% `{hydration_failed, _}' are dead and failed aggregates, never passivation,
%%% and neither may be retried.
-module(evoq_router_passivation_race_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(PROBE, evoq_strong_probe_aggregate).
-define(STORE, passivation_race_store).

race_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun a_passivated_aggregate_is_dispatched_again/0,
        fun a_dead_aggregate_that_never_comes_back_is_bounded/0,
        fun a_hydration_failure_is_not_retried/0,
        fun a_shutdown_is_not_retried/0
    ]}.

start() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    Started.

stop(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)).

%%====================================================================
%% The race: a pid that was alive at the lookup and gone at the call
%%====================================================================

%% The aggregate is asked again and the command runs on a fresh process. The
%% version and the event list are the answers of the attempt that ran, and one
%% append reached the store: a retry that appended twice would be a worse
%% defect than the one this replaces.
a_passivated_aggregate_is_dispatched_again() ->
    Stream = unique(<<"passivated">>),
    with_store(fun empty_read/5,
      fun() ->
          Passivated = passivated_aggregate(Stream),
          with_registry([{ok, Passivated}], fun(Counter) ->
              ?assertMatch({ok, _, [_]}, dispatch(Stream, #{})),
              %% Asked once for the stale pid, then again for the live one.
              ?assertEqual(2, asks(Counter)),
              ?assertEqual(1, appends())
          end)
      end).

%% The retry is bounded by `retry_attempts', not a loop: an aggregate that is
%% gone every time it is looked up ends as the error it is, after the attempts
%% the caller asked for. One retry attempt means two asks and no more.
a_dead_aggregate_that_never_comes_back_is_bounded() ->
    Stream = unique(<<"never-comes-back">>),
    with_store(fun empty_read/5,
      fun() ->
          Passivated = passivated_aggregate(Stream),
          with_registry([{ok, Passivated}, {ok, Passivated}], fun(Counter) ->
              ?assertEqual({error, not_running},
                           dispatch(Stream, #{retry_attempts => 1})),
              ?assertEqual(2, asks(Counter)),
              ?assertEqual(0, appends())
          end)
      end).

%%====================================================================
%% The failures that are NOT the race, and must not be retried
%%====================================================================

%% An aggregate that cannot load its stream stops with
%% `{hydration_failed, Reason}' while its caller waits, and the caller is told
%% the reason (evoq_aggregate_hydration_failure_tests.erl holds that half).
%% It is a real failure: retrying would start a fresh aggregate for a stream
%% that still cannot be read, again and again, and answer `not_running' at the
%% end having hidden the cause.
a_hydration_failure_is_not_retried() ->
    Self = self(),
    Stream = unique(<<"hydration">>),
    Loads = counters:new(1, []),
    %% The first load is held open so a command can queue behind it, and any
    %% later load fails at once, so a router that retried this would burn its
    %% attempts quickly instead of hanging.
    Read = fun(_Store, _Stream, _From, _Count, _Dir) ->
                   counters:add(Loads, 1, 1),
                   case counters:get(Loads, 1) of
                       1 ->
                           Self ! {reading, self()},
                           receive go -> {error, timeout} end;
                       _ ->
                           {error, timeout}
                   end
           end,
    with_store(Read, fun() ->
        with_registry([], fun(Counter) ->
            spawn(fun() -> Self ! {answer, dispatch(Stream, #{})} end),
            Pid = await_reading(),
            ok = await_queued_call(Pid),
            Pid ! go,
            ?assertEqual({error, {hydration_failed, timeout}}, await_answer()),
            ?assertEqual(1, asks(Counter))
        end)
    end).

%% Killed while its command is queued: the caller waiting on that command is
%% answered the reason, not `not_running'. A router that treated every dead
%% aggregate as a passivated one would retry here, and the fresh aggregate
%% would be killed by nothing at all.
a_shutdown_is_not_retried() ->
    Self = self(),
    Stream = unique(<<"shutdown">>),
    Read = fun(_Store, _Stream, _From, _Count, _Dir) ->
                   Self ! {reading, self()},
                   receive go -> {error, timeout} end
           end,
    with_store(Read, fun() ->
        with_registry([], fun(Counter) ->
            spawn(fun() -> Self ! {answer, dispatch(Stream, #{})} end),
            Pid = await_reading(),
            ok = await_queued_call(Pid),
            exit(Pid, shutdown),
            ?assertEqual({error, shutdown}, await_answer()),
            ?assertEqual(1, asks(Counter))
        end)
    end).

%%====================================================================
%% Helpers: the two seams
%%====================================================================

empty_read(_Store, _Stream, _From, _Count, _Dir) ->
    {ok, []}.

%% The event store is mocked: these tests are about what the router asks for
%% and how many times it appends, and nothing here needs a real stream.
with_store(Read, Body) ->
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5, Read),
    meck:expect(evoq_event_store, append, 4,
                fun(_Store, _Stream, _Expected, _Events) -> {ok, 1} end),
    try Body() after meck:unload(evoq_event_store) end.

%% A real aggregate that has already passivated. `passivate/1' stops it with
%% reason `normal' and `gen_server:stop/1' is that same stop, so this is the
%% process the registry hands out a moment before the lifespan fires.
passivated_aggregate(Stream) ->
    {ok, Pid} = evoq_aggregate_registry:get_or_start(?PROBE, Stream, ?STORE),
    ok = gen_server:stop(Pid),
    ok = await_dead(Pid),
    Pid.

%% The registry answers from a list, once per ask, and hands every ask past the
%% end of it to the real implementation. The counter is the evidence of how
%% many times the router asked.
with_registry(Answers, Body) ->
    Counter = counters:new(1, []),
    meck:new(evoq_aggregate_registry, [passthrough, no_link]),
    meck:expect(evoq_aggregate_registry, get_or_start, 3,
                fun(Module, Id, Store) ->
                        counters:add(Counter, 1, 1),
                        asked_times(Answers, counters:get(Counter, 1),
                                    [Module, Id, Store])
                end),
    try Body(Counter) after meck:unload(evoq_aggregate_registry) end.

asked_times(Answers, Asked, _Args) when Asked =< length(Answers) ->
    lists:nth(Asked, Answers);
asked_times(_Answers, _Asked, Args) ->
    meck:passthrough(Args).

asks(Counter) ->
    counters:get(Counter, 1).

%%====================================================================
%% Helpers: dispatch
%%====================================================================

dispatch(Stream, Extra) ->
    evoq_command_router:dispatch(command(Stream),
                                 maps:merge(#{store_id => ?STORE}, Extra)).

command(Stream) ->
    evoq_command:new(emit_probe, ?PROBE, Stream, #{command_type => <<"emit_strong_probe">>}).

%%====================================================================
%% Helpers: waiting
%%====================================================================

appends() ->
    meck:num_calls(evoq_event_store, append, 4).

await_reading() ->
    receive
        {reading, Pid} -> Pid
    after 5000 ->
        error(never_started_reading)
    end.

await_answer() ->
    receive
        {answer, Reply} -> Reply
    after 5000 ->
        error(no_answer)
    end.

%% The call queued behind the load: a gen_server does not read its mailbox
%% until the continue has returned, so this polls its own queue length.
await_queued_call(Pid) ->
    await_queued_call(Pid, 200).

await_queued_call(_Pid, 0) ->
    error(never_queued);
await_queued_call(Pid, N) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, 0} ->
            timer:sleep(5),
            await_queued_call(Pid, N - 1);
        {message_queue_len, _} ->
            ok;
        undefined ->
            error(process_gone_before_the_call_queued)
    end.

await_dead(Pid) ->
    await_dead(Pid, 200).

await_dead(_Pid, 0) ->
    error(never_died);
await_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(5),
            await_dead(Pid, N - 1)
    end.

unique(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
