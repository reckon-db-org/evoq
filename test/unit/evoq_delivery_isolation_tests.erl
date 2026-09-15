%% @doc Red-first tests for delivery isolation (Vulcan criterion 1,
%% original defects 1 & 2).
%%
%% These assert the invariant the fix must achieve: a handler that is
%% parked mid-event, or serving out a retry backoff, never delays
%% delivery to an unrelated handler, and no retry ever sleeps in a shared
%% process.
%%
%% They FAIL on evoq 1.23.3, where evoq_event_router fans out with a
%% sequential `lists:foreach' of `gen_server:call(..., infinity)' and a
%% `{retry, Delay}' is a `timer:sleep/1' inside the handler's own
%% (router-blocked) handle_call.
-module(evoq_delivery_isolation_tests).

-include_lib("eunit/include/eunit.hrl").

%% A second, unrelated handler must be served well inside this window
%% even while another handler is parked for 60s or backing off for 3s.
-define(PROMPT_DEADLINE_MS, 500).

%% `foreach' (not `setup'): each test gets a freshly (re)started evoq
%% app, so a handler parked in one test can never leave the router
%% blocked for the next -- each test must fail or pass on its own merit.
isolation_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [
      {"a parked handler does not delay an unrelated handler",
       fun slow_handler_does_not_block_other_handler/0},
      {"a handler serving out a retry backoff does not block the router",
       fun retry_backoff_does_not_block_router/0},
      {"the retried event is not lost while other handlers stay live",
       fun retry_event_still_completes/0},
      {"a projection receives events routed through the router",
       fun projection_receives_routed_event/0},
      {"a raising handler does not lose its queued events",
       fun raise_does_not_lose_queue/0},
      {"per-handler order is preserved across a retry",
       fun order_preserved_across_retry/0},
      {"a raising projection does not lose its queued events",
       fun raising_projection_keeps_queue/0},
      {"an unexpected handler return does not lose the queue",
       fun bad_return_does_not_lose_queue/0},
      {"a bad return's error term keeps only its shape, not its payload",
       fun bad_return_keeps_only_shape/0},
      {"a dead-lettered bad return carries no payload into the dead letter",
       fun bad_return_keeps_no_payload_in_dead_letter/0}
     ]}.

setup() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, _} = application:ensure_all_started(evoq),
    ok.

cleanup(_) ->
    application:stop(evoq),
    ok.

%%====================================================================
%% Tests
%%====================================================================

slow_handler_does_not_block_other_handler() ->
    {ok, Blocking} = start_handler(evoq_blocking_handler),
    {ok, Prompt} = start_handler(evoq_prompt_handler),

    %% Park the blocking handler mid-event.
    route(<<"blocking_evt_v1">>, <<"b1">>),
    ?assertEqual(ok, await({blocking_started, <<"b1">>}, 1000)),

    %% An unrelated event to an unrelated handler must still be served.
    route(<<"prompt_evt_v1">>, <<"p1">>),
    ?assertEqual(ok, await({prompt_handled, <<"p1">>}, ?PROMPT_DEADLINE_MS)),

    stop_handlers([Blocking, Prompt]).

retry_backoff_does_not_block_router() ->
    {ok, Backoff} = start_handler(evoq_backoff_handler),
    {ok, Prompt} = start_handler(evoq_prompt_handler),

    %% First attempt fails and the handler enters a 3s backoff.
    route(<<"backoff_evt_v1">>, <<"x1">>),
    ?assertEqual(ok, await({backoff_attempt, <<"x1">>, 1}, 1000)),

    %% While that backoff is outstanding, an unrelated handler must be
    %% served promptly -- the backoff must not sleep in a shared process.
    route(<<"prompt_evt_v1">>, <<"p2">>),
    ?assertEqual(ok, await({prompt_handled, <<"p2">>}, ?PROMPT_DEADLINE_MS)),

    stop_handlers([Backoff, Prompt]).

retry_event_still_completes() ->
    {ok, Backoff} = start_handler(evoq_backoff_handler),

    route(<<"backoff_evt_v1">>, <<"y1">>),
    ?assertEqual(ok, await({backoff_attempt, <<"y1">>, 1}, 1000)),
    %% The second attempt (after backoff) succeeds: the event is retried,
    %% not dropped.
    ?assertEqual(ok, await({backoff_succeeded, <<"y1">>}, 6000)),

    stop_handlers([Backoff]).

%% Ranked-first regression: a projection registers in the same registry
%% as a handler, so the router now casts {deliver, ...} to it too. If the
%% projection ignores that cast, every read model silently stops updating.
projection_receives_routed_event() ->
    {ok, Proj} = evoq_projection:start_link(evoq_test_projection, #{}, #{}),

    route_data(<<"proj_evt_v1">>, <<"pe1">>, #{item_id => <<"widget-1">>}),

    ?assertEqual(ok, poll_read_model(Proj, {item, <<"widget-1">>}, 2000)),

    stop_handlers([Proj]).

raise_does_not_lose_queue() ->
    {ok, Raising} = start_unlinked(evoq_raising_handler),

    %% Event 1 raises; 2 and 3 are queued behind it.
    route(<<"raise_evt_v1">>, <<"boom">>),
    route(<<"raise_evt_v1">>, <<"r2">>),
    route(<<"raise_evt_v1">>, <<"r3">>),

    %% The queued events still complete...
    ?assertEqual(ok, await({raise_handled, <<"r2">>}, 2000)),
    ?assertEqual(ok, await({raise_handled, <<"r3">>}, 2000)),
    %% ...in the same process (the raise did not kill the handler).
    ?assert(is_process_alive(Raising)),

    stop_handlers([Raising]).

order_preserved_across_retry() ->
    {ok, Ordering} = start_handler(evoq_ordering_handler),

    %% "a" fails once then succeeds; "b" and "c" queue behind its retry.
    route(<<"order_evt_v1">>, <<"a">>),
    route(<<"order_evt_v1">>, <<"b">>),
    route(<<"order_evt_v1">>, <<"c">>),

    Order = collect_ordered(order_handled, 3, 3000),
    ?assertEqual([<<"a">>, <<"b">>, <<"c">>], Order),

    stop_handlers([Ordering]).

%% A projection that raises in project/4 must not crash its process and
%% lose the events queued behind the failed one.
raising_projection_keeps_queue() ->
    {ok, Proj} = start_unlinked_projection(evoq_raising_projection),

    %% Distinct global versions: a projection's idempotency guard skips any
    %% event at or below its checkpoint, so the events must advance it.
    route_data_v(<<"raise_proj_evt_v1">>, <<"boom">>, #{item_id => <<"boom">>}, 1),
    route_data_v(<<"raise_proj_evt_v1">>, <<"pe2">>, #{item_id => <<"pe2">>}, 2),
    route_data_v(<<"raise_proj_evt_v1">>, <<"pe3">>, #{item_id => <<"pe3">>}, 3),

    ?assertEqual(ok, poll_read_model(Proj, {item, <<"pe2">>}, 2000)),
    ?assertEqual(ok, poll_read_model(Proj, {item, <<"pe3">>}, 2000)),
    ?assert(is_process_alive(Proj)),

    stop_handlers([Proj]).

%% A handler that returns a value matching neither {ok, _} nor {error, _}
%% must take the error path, not raise try_clause and lose its queue.
bad_return_does_not_lose_queue() ->
    {ok, Handler} = start_unlinked(evoq_bad_return_handler),

    route(<<"ret_evt_v1">>, <<"badret">>),
    route(<<"ret_evt_v1">>, <<"rr2">>),
    route(<<"ret_evt_v1">>, <<"rr3">>),

    ?assertEqual(ok, await({ret_handled, <<"rr2">>}, 2000)),
    ?assertEqual(ok, await({ret_handled, <<"rr3">>}, 2000)),
    ?assert(is_process_alive(Handler)),

    stop_handlers([Handler]).

%% A bad return can carry event data or handler state; the error term
%% derived from it must keep only the return's shape (tag + arity), so no
%% payload rides into on_error, a dead letter, or a log.
bad_return_keeps_only_shape() ->
    {ok, Handler} = start_handler(evoq_leaky_return_handler),

    route(<<"leak_evt_v1">>, <<"leak1">>),

    Error = receive {captured_error, E} -> E after 2000 -> timeout end,
    ?assertEqual({bad_return, {oops, 2}}, Error),

    stop_handlers([Handler]).

%% The shape reduction happens in run_callback/5 before the error flows
%% anywhere, so the same protection covers the dead-letter path: a
%% dead-lettered bad return carries the shape, never the returned secret,
%% in either its error field or its failure context. (Logs are covered by
%% the same source: no code path logs the return term, only the shape.)
bad_return_keeps_no_payload_in_dead_letter() ->
    {ok, Handler} = start_handler(evoq_leaky_deadletter_handler),

    route(<<"dl_evt_v1">>, <<"dl1">>),

    Entry = await_dead_letter(evoq_leaky_deadletter_handler, 2000),
    Secret = <<"secret-payload-xyz">>,
    ?assertEqual(nomatch, binary:match(term_to_binary(Entry), Secret)),

    stop_handlers([Handler]).

await_dead_letter(_Handler, Remaining) when Remaining =< 0 ->
    erlang:error(no_dead_letter);
await_dead_letter(Handler, Remaining) ->
    first_dead_letter(evoq_dead_letter:list(#{handler => Handler}), Handler, Remaining).

first_dead_letter([Entry | _], _Handler, _Remaining) ->
    Entry;
first_dead_letter([], Handler, Remaining) ->
    timer:sleep(25),
    await_dead_letter(Handler, Remaining - 25).

%%====================================================================
%% Helpers
%%====================================================================

start_handler(Module) ->
    evoq_event_handler:start_link(Module, #{report_to => self()}, #{}).

%% Unlinked so a deliberate handler crash in a test can't take the test
%% process down with it (and we can then assert on the handler's liveness).
start_unlinked(Module) ->
    {ok, Pid} = start_handler(Module),
    true = unlink(Pid),
    {ok, Pid}.

start_unlinked_projection(Module) ->
    {ok, Pid} = evoq_projection:start_link(Module, #{}, #{}),
    true = unlink(Pid),
    {ok, Pid}.

stop_handlers(Pids) ->
    lists:foreach(fun stop_handler/1, Pids).

stop_handler(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

route(Type, Id) ->
    route_data(Type, Id, #{}).

route_data(Type, Id, Data) ->
    route_data_v(Type, Id, Data, 0).

route_data_v(Type, Id, Data, Version) ->
    Event = #{event_type => Type, event_id => Id, data => Data},
    Metadata = #{stream_id => <<"stream">>, version => Version, epoch_us => 0},
    evoq_event_router:route_event(Event, Metadata).

await(Msg, Timeout) ->
    receive Msg -> ok
    after Timeout -> {timeout, Msg}
    end.

%% Poll the projection's read model until Key is present or the deadline
%% passes -- a bounded wait, no fixed sleep.
poll_read_model(_Proj, _Key, Remaining) when Remaining =< 0 ->
    {timeout, read_model};
poll_read_model(Proj, Key, Remaining) ->
    RM = evoq_projection:get_read_model(Proj),
    check_read_model(evoq_read_model:get(Key, RM), Proj, Key, Remaining).

check_read_model({ok, _Value}, _Proj, _Key, _Remaining) ->
    ok;
check_read_model({error, _}, Proj, Key, Remaining) ->
    timer:sleep(25),
    poll_read_model(Proj, Key, Remaining - 25).

%% Collect N ordered report messages of the given tag, returning their
%% ids in completion order.
collect_ordered(_Tag, 0, _Timeout) ->
    [];
collect_ordered(Tag, N, Timeout) ->
    receive
        {Tag, Id} -> [Id | collect_ordered(Tag, N - 1, Timeout)]
    after Timeout -> erlang:error({timeout, Tag, N})
    end.
