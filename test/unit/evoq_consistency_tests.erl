%%% @doc What `strong' consistency waits for (evoq#23).
%%%
%%% `strong' was a no-op by construction: `handlers => all' collapsed to an
%%% empty required list and `wait_loop/4' answered that at once, so a caller
%%% that asked for the guarantee got none. The mechanics are tested here
%%% without a store: `open/2' before the append, `await/4' after it, and the
%%% acks in between, keyed on (store, stream) with the version riding along.
-module(evoq_consistency_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% A wait that names no handlers
%%====================================================================

%% `all' cannot be resolved by a function that sees no events: it would have
%% to look up which handlers the dispatch reaches, and this one is not
%% dispatching. Answering `ok' there is what made strong lie.
a_wait_that_names_no_handlers_is_refused_test() ->
    ?assertEqual({error, all_needs_events},
                 evoq_consistency:wait_for(test_store, <<"s-no-handlers">>, 1, #{timeout => 10})).

%%====================================================================
%% Acks and the version they carry
%%====================================================================

%% A handler that writes after the wait started is counted, and the wait
%% returns as soon as it does rather than at the timeout.
a_handler_that_writes_before_the_timeout_is_counted_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-late">>),
    Self = self(),
    Acker = spawn_link(fun() ->
        receive go -> ok end,
        ok = evoq_consistency:acknowledge(slow_handler, test_store, <<"s-late">>, 3),
        Self ! acked
    end),
    Acker ! go,
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [slow_handler], 3, #{timeout => 5000})),
    ?assert(erlang:monotonic_time(millisecond) - Started < 2000),
    ok = evoq_consistency:close(Waiter).

%% THE RACE THE ISSUE IS ABOUT. A handler can finish before the router is
%% back from the append, so its ack is sent before `await/4' is called. It
%% is not lost: the waiter joined the group before the append, and the ack
%% is waiting in its mailbox.
an_ack_that_arrives_before_the_wait_counts_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-early">>),
    ok = evoq_consistency:acknowledge(eager_handler, test_store, <<"s-early">>, 4),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [eager_handler], 4, #{timeout => 5000})),
    %% Proves the ack was used and not the clock: the timeout is 5 s.
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    ok = evoq_consistency:close(Waiter).

%% An ack for a version the handler has already passed counts: the write it
%% describes covers the version being waited on.
an_ack_past_the_waited_version_counts_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-ahead">>),
    ok = evoq_consistency:acknowledge(ahead_handler, test_store, <<"s-ahead">>, 9),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [ahead_handler], 5, #{timeout => 500})),
    ok = evoq_consistency:close(Waiter).

%% AND AN ACK BEHIND IT DOES NOT. A handler that has written version 2 has
%% not written version 5, and saying otherwise would hand a caller a read
%% model that is still missing its event.
an_ack_behind_the_waited_version_does_not_count_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-behind">>),
    ok = evoq_consistency:acknowledge(behind_handler, test_store, <<"s-behind">>, 2),
    ?assertEqual({error, timeout},
                 evoq_consistency:await(Waiter, [behind_handler], 5, #{timeout => 100})),
    ok = evoq_consistency:close(Waiter).

%%====================================================================
%% Identity: the pid that wrote, or the module it names
%%====================================================================

an_ack_counts_for_the_module_it_names_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-module">>),
    acker(mod_b, <<"s-module">>, 8),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [mod_b], 8, #{timeout => 1000})),
    ok = evoq_consistency:close(Waiter).

an_ack_counts_for_the_process_that_wrote_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-pid">>),
    Acker = acker(mod_c, <<"s-pid">>, 8),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [Acker], 8, #{timeout => 1000})),
    ok = evoq_consistency:close(Waiter).

%% A waiter is told about its own stream only: another stream's ack, even
%% with the same handler and version, is not this dispatch's write.
an_ack_for_another_stream_is_not_counted_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-mine">>),
    ok = evoq_consistency:acknowledge(handler_a, test_store, <<"s-other">>, 5),
    ?assertEqual({error, timeout}, evoq_consistency:await(Waiter, [handler_a], 5, #{timeout => 100})),
    ok = evoq_consistency:close(Waiter).

%%====================================================================
%% Nothing to wait for
%%====================================================================

%% A dispatch whose events nobody subscribes to has no handler that could be
%% behind it. That is an answer at once, not five seconds and an error.
an_empty_required_list_waits_for_nothing_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-nobody">>),
    Started = erlang:monotonic_time(millisecond),
    ?assertEqual(ok, evoq_consistency:await(Waiter, [], 1, #{timeout => 5000})),
    ?assert(erlang:monotonic_time(millisecond) - Started < 1000),
    ok = evoq_consistency:close(Waiter).

%% Closing twice is what a crash in the middle of a dispatch produces: the
%% `after' runs on a waiter that was already closed.
closing_a_waiter_twice_is_harmless_test() ->
    Waiter = evoq_consistency:open(test_store, <<"s-close">>),
    ?assertEqual(ok, evoq_consistency:close(Waiter)),
    ?assertEqual(ok, evoq_consistency:close(Waiter)).

%%====================================================================
%% Helpers
%%====================================================================

%% A process that acknowledges one stream version, as a handler does after
%% its write, and reports its pid.
acker(Module, StreamId, Version) ->
    Self = self(),
    Acker = spawn_link(fun() ->
        receive go -> ok end,
        ok = evoq_consistency:acknowledge(Module, test_store, StreamId, Version),
        Self ! {acked, self()}
    end),
    Acker ! go,
    receive {acked, Acker} -> Acker after 1000 -> error(handler_did_not_ack) end.
