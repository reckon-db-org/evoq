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

%% @private
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
deliver(Handler, Store, Stream, #{event_type := EventType, data := Data} = Appended) ->
    Metadata = (maps:get(metadata, Appended, #{}))#{
        store_id => Store,
        stream_id => Stream,
        version => ?STREAM_VERSION,
        stream_version => ?STREAM_VERSION,
        global_position => 0
    },
    Event = #{event_type => EventType, stream_id => Stream, data => Data,
              version => ?STREAM_VERSION},
    evoq_event_handler:notify(Handler, EventType, Event, Metadata).
