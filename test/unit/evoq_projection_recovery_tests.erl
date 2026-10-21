%% @doc A projection that fails, and a projection that rebuilds.
%%
%% Two things a projection promised and did not do (GY-AW alignment,
%% reckon-db-org/evoq#22):
%%
%% 1. `{error, Reason}' from project/4 was swallowed. on_error/4 was called
%%    and the action it returned thrown away, the error went back to a
%%    router that discarded the reply, and the next event projected
%%    successfully moved the checkpoint past the failed one. The event was
%%    lost for good and nothing said so. It is now handled exactly as an
%%    event handler is: retry, {retry, Delay}, skip, stop or dead letter.
%%
%% 2. A rebuild cleared the read model and reset the checkpoint but kept the
%%    projection's own state, so the whole log was replayed on top of state
%%    that already reflected it. init/1 runs again now.
%%
%% This module is its own projection, so each test scripts exactly how it
%% fails and how many times.
-module(evoq_projection_recovery_tests).

-behaviour(evoq_projection).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").
-include("evoq_telemetry.hrl").

-export([interested_in/0, init/1, project/4, on_error/4]).

-define(TYPE, <<"recovery_probe_v1">>).

%%====================================================================
%% Tests
%%====================================================================

%% retry: the first attempt fails, the retry succeeds, and the event is
%% projected - not dropped.
retry_action_projects_the_event_on_the_next_attempt_test_() ->
    with_projection(fun(Pid) ->
        fail_times(1, 1),
        set_action(retry),
        ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
        ?assertEqual([1], projected(Pid)),
        ?assertEqual(0, evoq_projection:get_checkpoint(Pid))
    end).

%% skip: the projection refuses the event, the checkpoint still advances
%% (it does not want this event, which is not the same as failing to see
%% it) and the next event is projected.
skip_action_advances_the_checkpoint_test_() ->
    with_projection(fun(Pid) ->
        fail_times(1, 5),
        set_action(skip),
        ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
        ?assertEqual([], projected(Pid)),
        ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
        ok = evoq_projection:notify(Pid, ?TYPE, event(2), #{version => 1}),
        ?assertEqual([2], projected(Pid)),
        ?assertEqual(1, evoq_projection:get_checkpoint(Pid))
    end).

%% dead letter: the event is stored for an operator and the projection
%% carries on.
dead_letter_action_stores_the_event_and_carries_on_test_() ->
    with_projection(?MODULE, [evoq_dead_letter], #{}, fun(Pid) ->
        meck:expect(evoq_dead_letter, store, fun(_E, _M, _C, _R) -> ok end),
        fail_times(1, 5),
        set_action({dead_letter, too_many_refunds}),
        ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
        ?assertEqual([], projected(Pid)),
        ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
        ?assertEqual(1, meck:num_calls(evoq_dead_letter, store, 4)),
        ?assertEqual([too_many_refunds],
                     [Reason || {_Pid, {_, _, [_, _, _, Reason]}, _Result}
                                    <- meck:history(evoq_dead_letter)])
    end).

%% stop: the projection says it cannot continue, and the process ends
%% instead of pretending it handled the event.
stop_action_stops_the_projection_test_() ->
    with_projection(fun(Pid) ->
        fail_times(1, 5),
        set_action(stop),
        unlink(Pid),
        MRef = erlang:monitor(process, Pid),
        ?assertEqual({error, {projection_stopped, {boom, 1}}},
                     evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0})),
        %% The reply is sent before the process exits, so wait for it.
        Down = receive
                   {'DOWN', MRef, process, Pid, _} -> down
               after 2000 -> still_up
               end,
        ?assertEqual(down, Down)
    end).

%% rebuild: the projection's own state starts from init/1 again, so the
%% replay counts each event once.
%%
%% The projection is primed with an event the store does NOT hold (9), so
%% the three possible outcomes are all distinguishable: fresh state plus the
%% replay gives [1, 2]; keeping the old state gives [1, 9, 1, 2]; and a
%% rebuild that never replayed gives [1, 9].
rebuild_replays_on_fresh_state_test_() ->
    with_projection(?MODULE, [evoq_event_store], #{}, fun(Pid) ->
        meck:expect(evoq_event_store, read_all_global,
                    fun(_Store, _Offset, _Batch) ->
                        {ok, [stored_event(1, 0), stored_event(2, 1)]}
                    end),
        ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
        ok = evoq_projection:notify(Pid, ?TYPE, event(9), #{version => 2}),
        ?assertEqual([1, 9], projected(Pid)),

        ok = evoq_projection:rebuild(Pid),

        ?assertEqual([1, 2], projected(Pid)),
        ?assertEqual(1, evoq_projection:get_checkpoint(Pid))
    end).

%% A projection that stopped, or that the node restarted, comes back at its
%% checkpoint - and the events it missed are replayed from the store, because
%% the node's shared $all subscription has already moved past them and will
%% not deliver them again.
a_restarted_projection_resumes_from_its_checkpoint_test_() ->
    {timeout, 60, fun() ->
        meck:new(evoq_event_store, [passthrough]),
        try
            %% Honour the offset like the real store does: the resume
            %% replays twice (unregistered, then registered), and the second
            %% pass must find nothing left to read.
            meck:expect(evoq_event_store, read_all_global,
                        fun(_Store, Offset, _Batch) ->
                            Store = [{1, stored_event(2, 1)}, {2, stored_event(3, 2)}],
                            {ok, [E || {Pos, E} <- Store, Pos >= Offset]}
                        end),
            ensure_registry(),
            reset_script(),
            {ok, Pid} = evoq_projection:start_link(
                          ?MODULE, #{},
                          #{checkpoint_store => evoq_projection_resume_checkpoint}),
            try
                %% Position 0 was already projected before the restart; the
                %% events after it were missed and arrive through the resume.
                ?assertEqual([2, 3], projected(Pid)),
                ?assertEqual(2, evoq_projection:get_checkpoint(Pid))
            after
                stop(Pid)
            end
        after
            meck:unload(evoq_event_store)
        end
    end}.

%% A poison event under `stop` must not make the projection refuse to
%% boot. Before this, the resume ran in init/1 and answered {stop, _}: a
%% statically supervised projection failed the whole application's boot, and
%% a restarted one looped on the same event forever. It comes up halted and
%% behind now - the checkpoint says where it stopped - and it does not
%% project again until it is rebuilt.
%%
%% The script and the store's answer are set BEFORE start_link: the boot
%% resume runs inside init/1, so a mock arranged afterwards was never hit and
%% the assertions below held on a projection that had read nothing.
a_poison_event_on_resume_boots_halted_and_behind_test_() ->
    with_prepared_projection(
      ?MODULE, [evoq_event_store],
      #{checkpoint_store => evoq_projection_resume_checkpoint},
      fun() ->
              meck:expect(evoq_event_store, read_all_global,
                          fun(_Store, Offset, _Batch) ->
                                  Store = [{1, stored_event(2, 1)},
                                           {2, stored_event(3, 2)}],
                                  {ok, [E || {Pos, E} <- Store, Pos >= Offset]}
                          end),
              %% The first replayed event fails and on_error/4 says stop.
              fail_times(2, 5),
              set_action(stop),
              attach_halted_telemetry()
      end,
      fun(Pid) ->
              ?assert(is_process_alive(Pid)),
              %% Nothing was projected, and the checkpoint is the one it
              %% resumed from: behind, not pretending.
              ?assertEqual([], projected(Pid)),
              ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
              %% One halt, logged and counted once: the second pass is
              %% skipped, or the same poison would be reported twice.
              ?assertEqual(1, halted_telemetry_count()),
              %% And it IS halted: the next live event is refused instead of
              %% being projected over the hole and pulling the checkpoint
              %% past the event the projection refused.
              ?assertMatch({error, {halted, _}},
                           evoq_projection:notify(Pid, ?TYPE, event(7),
                                                  #{global_position => 5})),
              ?assertEqual([], projected(Pid)),
              ?assertEqual(0, evoq_projection:get_checkpoint(Pid))
      end).

%% A raise in project/4 during the resume is a failure like any other, not
%% an exit: it goes through on_error/4, which here says stop, and the
%% projection halts instead of refusing to boot. Before this, the raise
%% escaped `try read_all_global(...) of ...' - the `of' body is not covered
%% by the catch - and killed init/1.
a_raise_on_resume_halts_instead_of_refusing_to_boot_test_() ->
    with_prepared_projection(
      ?MODULE, [evoq_event_store],
      #{checkpoint_store => evoq_projection_resume_checkpoint},
      fun() ->
              meck:expect(evoq_event_store, read_all_global,
                          fun(_Store, Offset, _Batch) ->
                                  Store = [{1, stored_event(2, 1)}],
                                  {ok, [E || {Pos, E} <- Store, Pos >= Offset]}
                          end),
              raise_on(2),
              set_action(stop),
              attach_halted_telemetry()
      end,
      fun(Pid) ->
              ?assert(is_process_alive(Pid)),
              ?assertEqual([], projected(Pid)),
              ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
              ?assertEqual(1, halted_telemetry_count()),
              ?assertMatch({error, {halted, _}},
                           evoq_projection:notify(Pid, ?TYPE, event(7),
                                                  #{global_position => 5}))
      end).

%% And while it is live: a raise is reported through on_error/4 like an
%% {error, _}, so `skip' skips it and the process keeps running. Before this
%% a raise in project/4 exited the gen_server and the caller with it.
a_raise_while_live_goes_through_on_error_test_() ->
    with_projection(fun(Pid) ->
        raise_on(1),
        set_action(skip),
        ?assertEqual(ok, evoq_projection:notify(Pid, ?TYPE, event(1),
                                                #{version => 0})),
        ?assertEqual([], projected(Pid)),
        ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
        ?assert(is_process_alive(Pid))
    end).

%% The catch-up must not stall the node. It runs before the projection
%% registers, because registration is what makes the event router deliver to
%% it, and the router delivers with gen_server:call(..., infinity): a
%% projection replaying while registered would hold up every other handler
%% and process manager on the node for the length of its catch-up.
the_resume_runs_before_the_projection_registers_test_() ->
    {timeout, 30, fun resume_before_registration/0}.

%% @private
%%
%% Asked from inside the replay, which runs in the projection's own process:
%% "am I registered while I am catching up?". The answer must be no for the
%% first pass - registration is what makes the router call this process, and
%% it calls with infinity - and yes once start_link returns.
resume_before_registration() ->
    meck:new(evoq_event_store, [passthrough]),
    try
        ensure_registry(),
        reset_script(),
        Test = self(),
        Registered = fun(Pid) ->
                         lists:member(Pid, evoq_event_type_registry:get_handlers(?TYPE))
                     end,
        meck:expect(evoq_event_store, read_all_global,
                    fun(_Store, _Offset, _Batch) ->
                        Test ! {read_seen, self(), Registered(self())},
                        {ok, []}
                    end),

        _Starter = spawn(fun() ->
                             {ok, Pid} = evoq_projection:start_link(
                                           ?MODULE, #{},
                                           #{checkpoint_store =>
                                                 evoq_projection_resume_checkpoint}),
                             Test ! {started, Pid}
                         end),

        %% The first read happens during the first replay.
        ProjPid = receive
                      {read_seen, P, WasRegistered} ->
                          ?assertEqual(false, WasRegistered),
                          P
                  after 5000 -> ?assert(false)
                  end,

        %% The SECOND pass runs after registration: same process, and it
        %% must see itself registered.
        receive
            {read_seen, ProjPid, SecondWasRegistered} ->
                ?assertEqual(true, SecondWasRegistered)
        after 5000 -> ?assert(false)
        end,

        {started, StartedPid} = receive {started, P0} -> {started, P0}
                                 after 5000 -> ?assert(false) end,
        ?assertEqual(ProjPid, StartedPid),
        ?assertEqual(true, Registered(StartedPid)),
        unlink(StartedPid),
        gen_server:stop(StartedPid)
    after
        meck:unload(evoq_event_store)
    end.

%% A projection without on_error/4 gets the shared default - backoff and
%% retries - rather than a silent drop: here it fails once and the default
%% retry succeeds.
a_projection_without_on_error_retries_test_() ->
    with_raw_projection(fun(Pid) ->
        fail_times(1, 1),
        ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
        ?assertEqual([1], projected(Pid))
    end).

%%====================================================================
%% evoq_projection callbacks
%%====================================================================

interested_in() -> [?TYPE].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, [], RM}.

project(#{data := #{n := N}}, _Metadata, Seen, RM) ->
    case evoq_projection_recovery_script:raise_on() of
        N ->
            error({scripted_raise, N});
        _ ->
            case evoq_projection_recovery_script:take_failure(N) of
                true -> {error, {boom, N}};
                false -> {ok, Seen ++ [N], RM}
            end
    end.

on_error(_Reason, _Event, _FailureContext, _State) ->
    evoq_projection_recovery_script:action().

%%====================================================================
%% Scripting
%%====================================================================

with_raw_projection(Fun) ->
    with_projection(evoq_projection_recovery_deaf, [], #{}, Fun).

with_projection(Fun) ->
    with_projection(?MODULE, [], #{}, Fun).

with_checkpointed_projection(Module, Mecked, CheckpointStore, Fun) ->
    with_projection(Module, Mecked, #{checkpoint_store => CheckpointStore}, Fun).

%% One test spec, built here rather than nested inside another: a
%% {timeout, _, Fun} returned from *inside* a running test is just a value,
%% and a test that returns it passes without ever running.
with_projection(Module, Mecked, Opts, Fun) ->
    with_prepared_projection(Module, Mecked, Opts, fun() -> ok end, Fun).

%% As with_projection/4, but Prepare runs after the mecks are in place and
%% before start_link - which is what a test of the BOOT path needs, since the
%% resume runs inside init/1.
with_prepared_projection(Module, Mecked, Opts, Prepare, Fun) ->
    {timeout, 60, fun() ->
        [ok = meck:new(M, [passthrough]) || M <- Mecked],
        ensure_registry(),
        reset_script(),
        try
            ok = Prepare(),
            {ok, Pid} = evoq_projection:start_link(Module, #{}, Opts),
            try
                Fun(Pid)
            after
                stop(Pid)
            end
        after
            detach_halted_telemetry(),
            [meck:unload(M) || M <- Mecked]
        end
    end}.

%% Count [evoq, projection, halted] events for the current test.
attach_halted_telemetry() ->
    Test = self(),
    Ref = make_ref(),
    persistent_term:put({?MODULE, halted_ref}, Ref),
    telemetry:attach(Ref, ?TELEMETRY_PROJECTION_HALTED,
                     fun(_Event, _Measurements, Metadata, Pid) ->
                             Pid ! {halted_telemetry, Metadata}
                     end, Test),
    ok.

halted_telemetry_count() ->
    halted_telemetry_count(0).

halted_telemetry_count(N) ->
    receive
        {halted_telemetry, _Metadata} -> halted_telemetry_count(N + 1)
    after 200 -> N
    end.

detach_halted_telemetry() ->
    case persistent_term:get({?MODULE, halted_ref}, undefined) of
        undefined -> ok;
        Ref ->
            catch telemetry:detach(Ref),
            persistent_term:erase({?MODULE, halted_ref}),
            ok
    end.

reset_script() -> evoq_projection_recovery_script:reset().
fail_times(N, Count) -> evoq_projection_recovery_script:fail_times(N, Count).
set_action(Action) -> evoq_projection_recovery_script:set_action(Action).
raise_on(N) -> evoq_projection_recovery_script:raise_on(N).

%%====================================================================
%% Helpers
%%====================================================================

event(N) -> #{event_type => ?TYPE, data => #{n => N}}.

stored_event(N, Pos) ->
    #evoq_event{event_id = <<"evt-", (integer_to_binary(N))/binary>>,
                event_type = ?TYPE,
                stream_id = <<"recovery-stream">>,
                version = Pos,
                data = #{n => N},
                metadata = #{},
                tags = undefined,
                timestamp = Pos,
                epoch_us = Pos}.

%% The projection's own state is the list of what it projected, in order.
projected(Pid) ->
    element(3, sys:get_state(Pid)).

ensure_registry() ->
    %% telemetry:attach/4 needs the app; a module run on its own has not
    %% started it, and the halt assertion reads its events.
    {ok, _} = application:ensure_all_started(telemetry),
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link(), ok;
        _ -> ok
    end.

%% The stop test leaves the projection already dead, and a projection that
%% stopped carries a non-normal reason, so neither the aliveness check nor
%% an uncaught gen_server:stop is reliable here.
stop(Pid) ->
    unlink(Pid),
    catch gen_server:stop(Pid),
    ok.
