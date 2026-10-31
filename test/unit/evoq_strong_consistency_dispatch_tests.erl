%%% @doc `error/1': a dispatch that asks for the guarantee now gets it
%%% (evoq#23).
%%%
%%% The router is driven through `evoq_command_router:dispatch/2', the path a
%%% consumer uses, with the store mocked as `evoq_aggregate_noop_tests.erl'
%%% mocks it. The mock DELIVERS the appended event to a real
%%% `evoq_event_handler' inside the append call, which is the race the issue
%%% describes: the handler finishes before the router is back from the append,
%%% so its acknowledgment is sent before the router reaches its wait.
%%%
%%% What is measured, not assumed: a handler that takes 300 ms to write makes
%%% a `strong' dispatch take at least that long, and the handler's write has
%%% already happened when the dispatch returns. Before the fix a `strong'
%%% dispatch returned in about a millisecond, having waited for nothing.
-module(evoq_strong_consistency_dispatch_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STREAM_VERSION, 7).
-define(AFTER_HALT_BLANK, evoq_middleware_after_halt_blank).

%%====================================================================
%% The guarantee
%%====================================================================

%% THE CASE THE ISSUE IS ABOUT. A dispatch with `strong' must not answer
%% before the handler subscribed to its event has written. The mock delivers
%% from another process, as a store subscription does: the handler is still
%% working when the append returns, so only a real wait can see it finish.
a_slow_handlers_write_is_waited_for_test_() ->
    {timeout, 30, fun() ->
        with_probe(300, <<"stream-slow">>, spawn_delivery,
          fun() ->
              Started = erlang:monotonic_time(millisecond),
              ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(strong, <<"stream-slow">>)),
              Waited = erlang:monotonic_time(millisecond) - Started,
              ?assert(Waited >= 250),
              %% And the write is really in front of the caller, not merely
              %% somewhere in flight: the sink was told before the dispatch
              %% answered.
              receive {probe_wrote, <<"strong_probe_v1">>, _Event, _Metadata} -> ok
              after 0 -> error(the_dispatch_answered_before_the_handler_wrote)
              end
          end)
    end}.

%% The other half of the race, from the other side: a handler fast enough to
%% finish DURING the append acknowledges before the router reaches its wait,
%% and that ack must not be lost. Delivered inline, so it always wins.
an_ack_from_a_fast_handler_is_not_lost_test_() ->
    {timeout, 30, fun() ->
        with_probe(0, <<"stream-fast">>, inline_delivery,
          fun() ->
              ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(strong, <<"stream-fast">>))
          end)
    end}.

%% A dispatch whose events nobody subscribes to has no handler that could
%% be behind it: it answers at once rather than burning the timeout.
a_dispatch_nobody_subscribes_to_waits_for_nothing_test_() ->
    {timeout, 30, fun() ->
        with_probe(300, <<"stream-quiet">>, spawn_delivery,
          fun() ->
              Started = erlang:monotonic_time(millisecond),
              ?assertMatch({ok, ?STREAM_VERSION, [_]},
                           dispatch(strong, <<"emit_quiet_probe">>, <<"stream-quiet">>)),
              ?assert(erlang:monotonic_time(millisecond) - Started < 1000)
          end)
    end}.

%% A NAMED HANDLER LIST STILL WAITS, and it waits for the version the
%% dispatch produced, not for any ack at all.
a_named_handler_is_waited_for_test_() ->
    {timeout, 30, fun() ->
        with_probe(300, <<"stream-named">>, spawn_delivery,
          fun() ->
              Started = erlang:monotonic_time(millisecond),
              ?assertMatch({ok, ?STREAM_VERSION, [_]},
                           dispatch({handlers, [evoq_strong_probe_handler]}, <<"stream-named">>)),
              ?assert(erlang:monotonic_time(millisecond) - Started >= 250)
          end)
    end}.

%% A HANDLER THAT DROPPED THE EVENT IS NOT A WRITE. The handler's own error
%% policy answered `skip', so the event is in no read model: a strong
%% dispatch that answered `ok' would hand the caller a guarantee that is
%% false. It answers with the handler's name, at once, rather than waiting
%% out its deadline for an ack that is not coming.
a_handler_that_dropped_the_event_fails_the_dispatch_test_() ->
    {timeout, 30, fun() ->
        Started = erlang:monotonic_time(millisecond),
        ?assertEqual({error, {consistency_dropped, evoq_dropping_probe_handler}},
                     with_dropping_probe(fun() -> dispatch(strong, <<"stream-dropped">>) end)),
        ?assert(erlang:monotonic_time(millisecond) - Started < 3000)
    end}.

%% A DISPATCH THAT APPENDED TWO EVENTS WAITS FOR EACH HANDLER AT ITS OWN
%% VERSION. A handler subscribed to the first event wrote version 7 and
%% nothing else: holding it to the append's last version (8) is waiting for a
%% write it was never handed, and every such dispatch ends at the deadline.
%% Seen in macula-realm#92: a realm's initiation appends realm_initiated_v1
%% and realm_admin_appointed_v1, each projected by its own handler, and the
%% dispatch answered {error, consistency_timeout} with both rows written.
a_multi_event_append_waits_for_each_handler_at_its_own_version_test_() ->
    {timeout, 30, fun() ->
        with_two_probes(fun() ->
            Started = erlang:monotonic_time(millisecond),
            ?assertMatch({ok, 8, [_, _]},
                         dispatch(strong, <<"emit_two_probes">>, <<"stream-two">>)),
            ?assert(erlang:monotonic_time(millisecond) - Started < 3000),
            %% Both writes are in front of the caller: each handler was told
            %% its own event, at its own version, before the dispatch answered.
            ?assertMatch({messages, [{probe_wrote, <<"strong_probe_v1">>, _, _},
                                     {probe_wrote, <<"other_probe_v1">>, _, _}]},
                         {messages, drain_writes(2)})
        end)
    end}.

%% A CASCADE THAT DISPATCHES `strong' FROM ITS OWN handle_event/4 CANNOT WAIT
%% FOR ITSELF. The cascading handler subscribes to the event type its own
%% command appends, so the registry names the calling process in the required
%% set of its own dispatch, and it can never acknowledge while it is blocked
%% in the wait: the event it owes is the one it is inside of. Left in the set,
%% the dispatch ends at the deadline with the write made (macula-realm's
%% membership cascade). The caller is dropped from its own required set, so
%% the dispatch returns on the OTHER handler's ack, which is the guarantee it
%% can actually have.
a_cascade_does_not_wait_for_its_own_acknowledgement_test_() ->
    {timeout, 30, fun() ->
        with_cascade_probe(fun() ->
            %% Eventual, so the test is not the one waiting: the cascade runs
            %% inside the other handler's handle_event/4.
            ?assertMatch({ok, ?STREAM_VERSION, [_]},
                         dispatch(eventual, <<"emit_cascade_probe">>, <<"stream-cascade">>)),
            Result = receive
                         {cascade_result, R, Elapsed} -> {R, Elapsed}
                     after 10000 ->
                         error(the_cascade_never_returned)
                     end,
            ?assertMatch({{ok, ?STREAM_VERSION, [_]}, _}, Result),
            {_Ok, Waited} = Result,
            %% It waited for the handler that is NOT itself: 200 ms of write.
            ?assert(Waited >= 150)
        end)
    end}.

%%====================================================================
%% An after-stage halt may not erase a result the command already produced
%%====================================================================

%% THE EVENTUAL CASE (evoq#45). The command ran and the store accepted its
%% events. An `after_dispatch' middleware that halts and leaves no response
%% used to make the dispatch answer `undefined', which a caller that denies
%% only on `{error, _}' reads as an answer.
an_after_dispatch_halt_that_left_no_response_keeps_the_stored_result_test_() ->
    {timeout, 30, fun() ->
        with_probe(0, <<"stream-after-halt">>, inline_delivery,
          fun() ->
              ?assertMatch({ok, ?STREAM_VERSION, [_]},
                           dispatch_with_middleware(eventual, [?AFTER_HALT_BLANK],
                                                    <<"stream-after-halt">>))
          end)
    end}.

%% THE GUARANTEE CASE. The same halt used to skip the whole consistency wait:
%% a `strong' dispatch answered `undefined' in about a millisecond, having
%% waited for nothing, because `handle_consistency/4' only waits on a
%% `{ok, _, Appended}' response and the stored one had been erased.
an_after_dispatch_halt_that_left_no_response_still_waits_for_strong_test_() ->
    {timeout, 30, fun() ->
        with_probe(300, <<"stream-after-halt-strong">>, spawn_delivery,
          fun() ->
              Started = erlang:monotonic_time(millisecond),
              ?assertMatch({ok, ?STREAM_VERSION, [_]},
                           dispatch_with_middleware(strong, [?AFTER_HALT_BLANK],
                                                    <<"stream-after-halt-strong">>)),
              Waited = erlang:monotonic_time(millisecond) - Started,
              ?assert(Waited >= 250)
          end)
    end}.

%% THE FAILURE PATH, same shape: the store refused the append, the router put
%% `{error, store_down}' on the pipeline, and an `after_failure' halt that left
%% no response answered `undefined' instead of the error it replaced.
an_after_failure_halt_that_left_no_response_keeps_the_error_test_() ->
    {timeout, 30, fun() ->
        with_failing_store(fun() ->
            ?assertEqual({error, store_down},
                         dispatch_with_middleware(eventual, [?AFTER_HALT_BLANK],
                                                  <<"stream-after-halt-failure">>))
        end)
    end}.

%%====================================================================
%% Helpers
%%====================================================================

dispatch(Consistency, Stream) ->
    dispatch(Consistency, <<"emit_strong_probe">>, Stream).

dispatch(Consistency, CommandType, Stream) ->
    evoq_command_router:dispatch(
      evoq_command:new(strong_probe, evoq_strong_probe_aggregate, Stream,
                       #{command_type => CommandType}),
      #{store_id => test_store, consistency => Consistency}).

dispatch_with_middleware(Consistency, Middleware, Stream) ->
    evoq_command_router:dispatch(
      evoq_command:new(strong_probe, evoq_strong_probe_aggregate, Stream,
                       #{command_type => <<"emit_strong_probe">>}),
      #{store_id => test_store, consistency => Consistency, middleware => Middleware}).

%% A store whose append refuses: the dispatch takes the failure path, which is
%% where `after_failure' runs.
with_failing_store(Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(_Store, _Stream, _Expected, _Events) -> {error, store_down} end),
    try
        Body()
    after
        meck:unload(evoq_event_store),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% Every test dispatches to its OWN stream. EUnit runs one module's tests in
%% one process, so an acknowledgment left in the mailbox by an earlier test
%% on the same stream would satisfy this one's wait: the test would pass for
%% the wrong reason, which is the exact defect it exists to catch.
%% A real handler, the application up, and a store whose append delivers the
%% event to that handler exactly as a store subscription would: the metadata
%% carries the store, the stream and the event's own stream version, which is
%% what the handler acknowledges. `inline_delivery' hands the event over
%% inside the append call (the handler wins the race); `spawn_delivery'
%% hands it over from another process (the handler is still working when the
%% append returns), which is what a store subscription does.
with_probe(SleepMs, _Stream, Delivery, Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    {ok, Handler} = evoq_event_handler:start_link(
                      evoq_strong_probe_handler, #{sink => self(), sleep => SleepMs}),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(Store, Stream, _Expected, Events) ->
                    deliver_all(Delivery, Handler, Store, Stream, Events),
                    {ok, ?STREAM_VERSION}
                end),
    try
        Body()
    after
        %% The handler is stopped, not merely left to its link: it registers
        %% for the probe type, and a handler left registered by an earlier
        %% test would be in the required set of the next one and never ack
        %% it (it is not the one the store delivers to). That turned this
        %% suite green alone and red in the full run.
        catch gen_server:stop(Handler),
        meck:unload(evoq_event_store),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% The same store and delivery, with a handler that drops the event by its
%% own error policy. The timeout is the caller's (the dispatch's default), so
%% a dispatch that answered `ok' by waiting nothing, or that hung on an ack
%% that was never coming, both show here.
with_dropping_probe(Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    {ok, Handler} = evoq_event_handler:start_link(evoq_dropping_probe_handler, #{}),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(Store, Stream, _Expected, Events) ->
                    deliver_all(inline_delivery, Handler, Store, Stream, Events),
                    {ok, ?STREAM_VERSION}
                end),
    try
        Body()
    after
        catch gen_server:stop(Handler),
        meck:unload(evoq_event_store),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% Two real handlers, each subscribed to ONE of the two events the append
%% produces, delivered inline with the events' OWN stream versions: a store
%% subscription hands each event its own version, and a handler acknowledges
%% the one it was given. The mock answers the append's last version (8), so
%% the dispatch's range is 7..8.
with_two_probes(Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    %% EUnit runs one module's tests in one process: an earlier test's probe
    %% writes are still in this mailbox, and the assertions below are about
    %% this test's two.
    flush_sink(),
    {ok, Started} = application:ensure_all_started(evoq),
    {ok, Probe} = evoq_event_handler:start_link(evoq_strong_probe_handler,
                                                #{sink => self(), sleep => 0}),
    {ok, Other} = evoq_event_handler:start_link(evoq_other_probe_handler,
                                                #{sink => self()}),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(Store, Stream, _Expected, [First, Second]) ->
                    deliver(Probe, Store, Stream, First, 7),
                    deliver(Other, Store, Stream, Second, 8),
                    {ok, 8}
                end),
    try
        Body()
    after
        catch gen_server:stop(Probe),
        catch gen_server:stop(Other),
        meck:unload(evoq_event_store),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% @private The writes the probes reported, in the order they happened.
drain_writes(0) -> [];
drain_writes(N) ->
    receive {probe_wrote, _, _, _} = Write -> [Write | drain_writes(N - 1)]
    after 1000 -> error({missing_writes, N})
    end.

%% @private Empty the sink of what earlier tests' probes wrote.
flush_sink() ->
    receive {probe_wrote, _, _, _} -> flush_sink()
    after 0 -> ok
    end.

%% A cascading handler and a second handler on the same event type, both
%% registered, with the store delivering from ANOTHER process: delivering
%% inline would hand the cascading handler its own event inside its own call
%% (`notify/4' is a gen_server call), which is a different deadlock.
with_cascade_probe(Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    flush_sink(),
    {ok, Started} = application:ensure_all_started(evoq),
    {ok, Slow} = evoq_event_handler:start_link(evoq_strong_probe_handler,
                                               #{sink => self(), sleep => 200}),
    {ok, Cascade} = evoq_event_handler:start_link(evoq_cascading_probe_handler,
                                                  #{sink => self()}),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(Store, Stream, _Expected, Events) ->
                    deliver_all(spawn_delivery, [Slow, Cascade], Store, Stream, Events),
                    {ok, ?STREAM_VERSION}
                end),
    try
        Body()
    after
        catch gen_server:stop(Slow),
        catch gen_server:stop(Cascade),
        meck:unload(evoq_event_store),
        lists:foreach(fun application:stop/1, lists:reverse(Started))
    end.

%% @private A delivery to several handlers, as a store subscription reaches
%% every process registered for the type.
deliver_all(spawn_delivery, Handlers, Store, Stream, Events) when is_list(Handlers) ->
    _ = spawn(fun() ->
                  lists:foreach(
                    fun(Handler) ->
                            lists:foreach(fun(Event) -> deliver(Handler, Store, Stream, Event) end,
                                          Events)
                    end, Handlers)
              end),
    ok;
deliver_all(inline_delivery, Handler, Store, Stream, Events) ->
    lists:foreach(fun(Event) -> deliver(Handler, Store, Stream, Event) end, Events);
deliver_all(spawn_delivery, Handler, Store, Stream, Events) ->
    %% Unlinked: it can outlive the test body, and the application going down
    %% under it is not the test's business.
    _ = spawn(fun() ->
                  lists:foreach(fun(Event) -> deliver(Handler, Store, Stream, Event) end, Events)
              end),
    ok.

%% One appended event, as the store subscription hands it to the router.
deliver(Handler, Store, Stream, Event) ->
    deliver(Handler, Store, Stream, Event, ?STREAM_VERSION).

%% @private The same, at the event's own stream version: a multi-event append
%% gives each event the version it was appended at.
deliver(Handler, Store, Stream, #{event_type := EventType, data := Data} = Appended, Version) ->
    Metadata = (maps:get(metadata, Appended, #{}))#{
        store_id => Store,
        stream_id => Stream,
        version => Version,
        stream_version => Version,
        global_position => 0
    },
    Event = #{event_type => EventType, stream_id => Stream, data => Data,
              version => Version},
    evoq_event_handler:notify(Handler, EventType, Event, Metadata).
