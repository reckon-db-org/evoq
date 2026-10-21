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
    with_projection(?MODULE, [evoq_dead_letter], fun(Pid) ->
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
    with_projection(?MODULE, [evoq_event_store], fun(Pid) ->
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
            meck:expect(evoq_event_store, read_all_global,
                        fun(_Store, _Offset, _Batch) ->
                            {ok, [stored_event(2, 1), stored_event(3, 2)]}
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
    case evoq_projection_recovery_script:take_failure(N) of
        true -> {error, {boom, N}};
        false -> {ok, Seen ++ [N], RM}
    end.

on_error(_Reason, _Event, _FailureContext, _State) ->
    evoq_projection_recovery_script:action().

%%====================================================================
%% Scripting
%%====================================================================

with_raw_projection(Fun) ->
    with_projection(evoq_projection_recovery_deaf, [], Fun).

with_projection(Fun) ->
    with_projection(?MODULE, [], Fun).

%% One test spec, built here rather than nested inside another: a
%% {timeout, _, Fun} returned from *inside* a running test is just a value,
%% and a test that returns it passes without ever running.
with_projection(Module, Mecked, Fun) ->
    {timeout, 60, fun() ->
        [ok = meck:new(M, [passthrough]) || M <- Mecked],
        ensure_registry(),
        reset_script(),
        {ok, Pid} = evoq_projection:start_link(Module, #{}, #{}),
        try
            Fun(Pid)
        after
            stop(Pid),
            [meck:unload(M) || M <- Mecked]
        end
    end}.

reset_script() -> evoq_projection_recovery_script:reset().
fail_times(N, Count) -> evoq_projection_recovery_script:fail_times(N, Count).
set_action(Action) -> evoq_projection_recovery_script:set_action(Action).

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
