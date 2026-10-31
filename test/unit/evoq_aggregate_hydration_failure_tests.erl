%% @doc A store read that FAILS is never answered as a stream with nothing in it.
%%%
%%% `load_or_init/3' discarded the error `replay_read/5' had already classified:
%%% `replayed_or_fresh({error, _}, ...)' and `replayed_from_zero(_, ...)' both
%%% fell through to `init_fresh/2'. The process registered, stayed up at
%%% version -1 holding `Module:init/1''s state, and every later `get_state/1'
%%% returned it. A caller that gates on aggregate state -- a revoked station,
%%% an ended membership, a lapsed provider authorization -- was told "never
%%% happened" by a read error.
%%%
%%% A stream that does not exist is `{ok, []}' on the first page and is still a
%%% fresh aggregate. Only `{error, _}' changes: the process stops with
%%% `{hydration_failed, Reason}', and a caller that was waiting on it is
%%% answered `{error, {hydration_failed, Reason}}'.
%%%
%%% A caller that arrives AFTER the process is gone gets `{error, not_running}'
%%% rather than the cause -- `gen_server:call' to a dead pid cannot carry one.
%%% Both are errors; neither is a fresh aggregate, and both tests below hold
%%% that in place rather than asserting the nicer of the two everywhere.
%%%
%%% The failure has to be a RETURNED error and not a raise, which is why this
%%% mocks `evoq_event_store:read/5' rather than leaving the adapter unset: with
%%% no adapter the read raises, the continue crashes, and the process dies for
%%% a reason that has nothing to do with the defect.
-module(evoq_aggregate_hydration_failure_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%%====================================================================
%% The caller that was waiting on the load is told what happened
%%====================================================================

a_caller_waiting_on_the_load_is_told_the_reason_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> fun waiting_caller_is_told_the_reason/0 end}.

waiting_caller_is_told_the_reason() ->
    Self = self(),
    with_a_read_that_blocks_then_fails(
      Self,
      fun(Pid) ->
          Caller = spawn(fun() ->
                             Self ! {answer, evoq_aggregate:execute_command(Pid, command())}
                         end),
          ok = await_queued_call(Pid),
          %% Release the read. The process stops, and the call that has been
          %% sitting in its mailbox gets the exit reason, not a fresh state.
          Pid ! go,
          _ = Caller,
          ?assertEqual({error, {hydration_failed, timeout}}, await_answer()),
          ?assertNot(is_process_alive(Pid))
      end).

%%====================================================================
%% A caller that arrives after the process is gone still gets an error
%%====================================================================

a_late_caller_gets_an_error_and_never_a_fresh_aggregate_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> [fun late_read_of_state/0,
                       fun late_read_of_version/0,
                       fun late_command/0,
                       fun nothing_stays_registered/0] end}.

%% These used to be `{ok, #{status => active}}' at version -1, which is what a
%% revoked station read as "not revoked".
late_read_of_state() ->
    {Pid, _Id} = started_and_gone(),
    ?assertMatch({error, _}, evoq_aggregate:get_state(Pid)),
    ?assertNot(is_process_alive(Pid)).

late_read_of_version() ->
    {Pid, _Id} = started_and_gone(),
    ?assertMatch({error, _}, evoq_aggregate:get_version(Pid)),
    ?assertNot(is_process_alive(Pid)).

late_command() ->
    {Pid, _Id} = started_and_gone(),
    ?assertMatch({error, _}, evoq_aggregate:execute_command(Pid, command())),
    ?assertNot(is_process_alive(Pid)).

%% Nothing is left behind: a stream that could not be read is not a stream this
%% node now believes it has loaded, so the next caller starts a fresh load and
%% meets the store again rather than inheriting a wrong answer.
nothing_stays_registered() ->
    {Pid, Id} = started_and_gone(),
    ?assertNot(is_process_alive(Pid)),
    ?assertEqual({error, not_found}, evoq_aggregate_registry:lookup(Id)).

%%====================================================================
%% A stream WITH a snapshot: the tail read after it fails the same way
%%====================================================================

%% `evoq_aggregate_registry_test_agg' exports no `from_snapshot/1', so every
%% other test here takes the replay-from-zero path and reaches
%% `replayed_from_zero/3'. A stream that has a snapshot -- the long-lived ones,
%% which are the streams most likely to hold a revocation -- resumes its replay
%% through `replayed_or_fresh/3' instead, and that clause went untested until
%% Neptunus reverted it alone and watched all six of these still pass.
%%
%% The read is asserted to start at the snapshot's own version, so the test
%% cannot pass by quietly taking the from-zero path it is meant to sit beside.
a_failed_tail_read_after_a_snapshot_is_the_same_error_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> fun snapshot_then_a_failed_tail_read/0 end}.

snapshot_then_a_failed_tail_read() ->
    Self = self(),
    with_mocks({evoq_snapshot_store, load,
                fun(_Store, _Stream) ->
                    {ok, #{data => #{status => revoked, from => snapshot},
                           version => 1499}}
                end},
               fun() ->
                   with_mocks({evoq_event_store, read,
                               fun(_Store, _Stream, Start, _Count, forward) ->
                                   Self ! {read_start, Start},
                                   receive go -> {error, timeout} end
                               end},
                              fun() ->
                                  Id = fresh_id(<<"snapshot">>),
                                  %% `try_load_snapshot/3' asks
                                  %% `erlang:function_exported/3', which is false
                                  %% for a module the VM has not loaded yet --
                                  %% and nothing has called this fixture. In a
                                  %% service the aggregate module is loaded long
                                  %% before any load runs.
                                  {module, _} = code:ensure_loaded(
                                                  evoq_aggregate_hydration_snapshot_agg),
                                  {ok, Pid} = evoq_aggregate_registry:get_or_start(
                                                evoq_aggregate_hydration_snapshot_agg,
                                                Id, hydration_failure_store),
                                  %% A snapshot was loaded and the replay began
                                  %% one past its version: this is the snapshot
                                  %% path, not the from-zero one.
                                  ?assertEqual({read_start, 1500}, await_read_start()),
                                  Caller = spawn(fun() ->
                                                     Self ! {answer,
                                                             evoq_aggregate:get_state(Pid)}
                                                 end),
                                  ok = await_queued_call(Pid),
                                  Pid ! go,
                                  _ = Caller,
                                  ?assertEqual({error, {hydration_failed, timeout}},
                                               await_answer()),
                                  ?assertNot(is_process_alive(Pid))
                              end)
               end).

%%====================================================================
%% An empty stream is still a fresh aggregate -- the half that must not change
%%====================================================================

an_empty_stream_is_still_a_fresh_aggregate_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> fun empty_stream_is_fresh/0 end}.

empty_stream_is_fresh() ->
    with_mocks({evoq_event_store, read,
                fun(_Store, _Stream, _Start, _Count, forward) -> {ok, []} end},
               fun() ->
                   {ok, Pid} = get_or_start(fresh_id(<<"empty-stream">>)),
                   ?assertEqual({ok, #{status => active}},
                                evoq_aggregate:get_state(Pid)),
                   ?assertEqual({ok, -1}, evoq_aggregate:get_version(Pid)),
                   ?assert(is_process_alive(Pid))
               end).

%%====================================================================

%% An aggregate whose load fails with `{error, timeout}' while a read is
%% blocked, handed to Test so the caller can be queued before it is released.
with_a_read_that_blocks_then_fails(TestPid, Test) ->
    with_mocks({evoq_event_store, read,
                fun(_Store, _Stream, _Start, _Count, forward) ->
                    TestPid ! reading,
                    receive go -> {error, timeout} end
                end},
               fun() ->
                   {ok, Pid} = get_or_start(fresh_id(<<"blocked">>)),
                   ok = await_message(reading),
                   ?assert(is_process_alive(Pid)),
                   Test(Pid)
               end).

%% A pid whose load has already failed and taken the process with it. The mock
%% stays loaded until it has, so the failure is the store's RETURNED error and
%% not a raise from an unloaded module.
started_and_gone() ->
    Id = fresh_id(<<"unreadable">>),
    with_mocks({evoq_event_store, read,
                fun(_Store, _Stream, _Start, _Count, forward) -> {error, timeout} end},
               fun() ->
                   {ok, Pid} = get_or_start(Id),
                   ok = await_dead(Pid),
                   ?assertNot(is_process_alive(Pid)),
                   {Pid, Id}
               end).

get_or_start(Id) ->
    evoq_aggregate_registry:get_or_start(
      evoq_aggregate_registry_test_agg, Id, hydration_failure_store).

%%====================================================================

await_message(Expected) ->
    receive
        Expected -> ok
    after 5000 ->
        error({no_message, Expected})
    end.

await_answer() ->
    receive
        {answer, Reply} -> Reply
    after 5000 ->
        error(no_answer)
    end.

await_read_start() ->
    receive
        {read_start, Start} -> {read_start, Start}
    after 5000 ->
        error(no_read)
    end.

%% The call queued behind the load: a gen_server does not read its mailbox
%% until the continue has returned, so this polls its own queue length.
await_queued_call(Pid) ->
    await_queued_call(Pid, 200).

await_queued_call(_Pid, 0) -> error(never_queued);
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

%% Wait on the pid itself, not on pg: a group join is not visible to every
%% reader the instant init makes it, so lookup can say `not_found' while the
%% process is very much alive.
await_dead(Pid) ->
    await_dead(Pid, 200).

await_dead(_Pid, 0) -> error(never_died);
await_dead(Pid, N) ->
    case is_process_alive(Pid) of
        false ->
            ok;
        true ->
            timer:sleep(5),
            await_dead(Pid, N - 1)
    end.

%% A mock unloaded even when the body raises, so one failing assertion does not
%% leave the module mocked for the next test.
with_mocks({Module, Function, Impl}, Body) ->
    meck:new(Module, [passthrough]),
    meck:expect(Module, Function, Impl),
    try Body() after meck:unload(Module) end.

fresh_id(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

command() ->
    evoq_command:new(test, evoq_aggregate_registry_test_agg, <<"hydration-failure">>,
                     #{command_type => test}).

start_deps() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    Started.

stop_deps(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)).
