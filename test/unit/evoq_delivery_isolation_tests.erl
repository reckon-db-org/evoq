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
       fun retry_event_still_completes/0}
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

%%====================================================================
%% Helpers
%%====================================================================

start_handler(Module) ->
    evoq_event_handler:start_link(Module, #{report_to => self()}, #{}).

stop_handlers(Pids) ->
    lists:foreach(fun stop_handler/1, Pids).

stop_handler(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

route(Type, Id) ->
    Event = #{event_type => Type, event_id => Id, data => #{}},
    Metadata = #{stream_id => <<"stream">>, version => 0, epoch_us => 0},
    evoq_event_router:route_event(Event, Metadata).

await(Msg, Timeout) ->
    receive Msg -> ok
    after Timeout -> {timeout, Msg}
    end.
