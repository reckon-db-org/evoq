%%% @doc The sanctioned no-op: an aggregate whose `execute/2' returns `{ok, []}'.
%%%
%%% A handler declines a command it has already honoured by producing no event,
%%% and the dispatch must come back as `{ok, Version, []}' with the stream's
%%% version UNCHANGED and the aggregate process still alive. It did not: the
%%% reply path called `hd/1' on the empty event list and the aggregate died with
%%% a `badarg', so the caller got an exit where the documented no-op should have
%%% been. Reported as evoq#16.
%%%
%%% Why it went unnoticed is the point of testing it HERE: no test in this
%%% repository ever drove `execute/2' to `{ok, []}'. The fixture below is a
%%% command handler that deduplicates, which is the shape a consumer uses and
%%% the shape this repository never exercised.
%%%
%%% `evoq_event_store' is mocked, in the same way
%%% evoq_aggregate_rebuild_tests.erl mocks it: the defect is in the aggregate's
%%% reply path, so the store only has to answer, not to work.
-module(evoq_aggregate_noop_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Aggregate fixture: a handler that deduplicates
%%====================================================================

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{seen => false}}.

%% The first time, there is something to say. After that, the stream already
%% holds it and the handler declines -- the no-op under test.
execute(#{seen := true}, #{command_type := <<"record_once">>}) ->
    {ok, []};
execute(_State, #{command_type := <<"record_once">>}) ->
    {ok, [#{event_type => <<"recorded_once_v1">>, post_id => <<"p1">>}]};
execute(_State, _Command) ->
    {error, unknown_command}.

apply(State, _Event) ->
    State#{seen => true}.

%%====================================================================
%% Tests
%%====================================================================

%% THE REGRESSION. A declined command answers `{ok, Version, []}' -- no events,
%% and the version the stream was already at -- and the aggregate is still
%% there to be asked again.
a_declined_command_replies_with_no_events_and_leaves_the_aggregate_alive_test() ->
    with_store(
      fun() ->
          {ok, Pid} = evoq_aggregate:start_link(?MODULE, <<"agg-1">>, test_store),
          {ok, Version, [_Event]} = evoq_aggregate:execute_command(Pid, command()),
          ?assertEqual({ok, Version, []}, evoq_aggregate:execute_command(Pid, command())),
          ?assert(erlang:is_process_alive(Pid)),
          %% Still answering after the no-op: a process that survived the reply
          %% but wedged in a bad state would pass the two assertions above.
          ?assertEqual({ok, #{seen => true}}, evoq_aggregate:get_state(Pid))
      end).

%% AND THE VERSION IS NOT A LIE. The no-op used to answer a hardcoded 0 however
%% far along the stream was, which is a version the stream may never have been
%% at. It answers the stream's own version now, so a caller that reads a version
%% off a no-op reads the truth.
a_declined_command_does_not_move_the_version_test() ->
    with_store(
      fun() ->
          {ok, Pid} = evoq_aggregate:start_link(?MODULE, <<"agg-2">>, test_store),
          {ok, Before, [_]} = evoq_aggregate:execute_command(Pid, command()),
          {ok, After, []} = evoq_aggregate:execute_command(Pid, command()),
          ?assertEqual(Before, After),
          ?assertEqual({ok, Before}, evoq_aggregate:get_version(Pid))
      end).

%% The no-op is the DECLINED case, not the general one: an accepted command
%% still produces its event and still moves the version. Without this the two
%% tests above would pass on an aggregate that simply never appended anything.
an_accepted_command_still_produces_its_event_test() ->
    with_store(
      fun() ->
          {ok, Pid} = evoq_aggregate:start_link(?MODULE, <<"agg-3">>, test_store),
          {ok, _Version, [Event]} = evoq_aggregate:execute_command(Pid, command()),
          ?assertEqual(<<"recorded_once_v1">>, maps:get(event_type, Event))
      end).

%% THE SAME DEFECT, ONE LAYER UP, and only under an EXPLICIT handler list.
%%
%% `strong' does not wait at all, measured: a declined dispatch came back
%% `{ok, -1, []}' in 0 ms on the unfixed router. `evoq_consistency:wait_for/4'
%% turns its default `all' into an EMPTY required-handler list and
%% `wait_loop/4' answers that immediately, so `strong' has nothing to time out
%% on. `{handlers, [M]}' is the shape that really waits, and it waits for an ack
%% that a command producing no event can never cause: measured at the full 5 s
%% default, answering `{error, consistency_timeout}' where the aggregate had
%% said `{ok, Version, []}'.
%%
%% Nothing was appended, so there is nothing for a handler to have caught up
%% with and nothing to wait for. A caller that wants to know handlers have
%% reached a version must ask about a version something actually wrote.
a_declined_dispatch_under_handlers_consistency_answers_at_once_test_() ->
    {timeout, 30, fun() ->
        with_store(
          fun() ->
              %% Accepted first, under the default consistency: the version this
              %% one produces is the version the declined dispatch must not wait
              %% on. (Under `strong' the accepted dispatch would wait for an ack
              %% only a registered handler could give, which is correct
              %% behaviour and not what this test is about.)
              {ok, Version, [_Event]} = dispatch(#{consistency => eventual}),

              Started = erlang:monotonic_time(millisecond),
              ?assertEqual({ok, Version, []},
                           dispatch(#{consistency => {handlers, [?MODULE]}})),
              Waited = erlang:monotonic_time(millisecond) - Started,
              %% The wait that must not happen is the 5 s default, so a second
              %% is a generous ceiling that still catches one running to it.
              ?assert(Waited < 1000)
          end)
    end}.

%%====================================================================
%% Helpers
%%====================================================================

command() ->
    evoq_command:new(record_once, ?MODULE, <<"agg-1">>,
                     #{command_type => <<"record_once">>}).

%% A command through the ROUTER, which is the path a consumer uses. The
%% aggregate id is the router's, so two dispatches reach the same aggregate
%% process and the second one finds the post already recorded.
dispatch(Opts) ->
    evoq_command_router:dispatch(
      evoq_command:new(record_once, ?MODULE, <<"dispatch-1">>,
                       #{command_type => <<"record_once">>}),
      Opts#{store_id => test_store}).

%% The aggregate is a REAL one -- it registers with `evoq_pg' in `init/1' and is
%% dispatched to through `evoq_aggregate' -- so the application has to be up, and
%% this module starts it rather than assuming the module before it left it
%% running. Assuming that is not a small thing to get wrong: run before a module
%% that starts it, every test here dies on `noproc' and eunit reports them as
%% cancelled, which reads exactly like a pass in the summary line.
%%
%% The store is mocked, so no adapter has to be configured: an empty stream, so
%% the aggregate starts from `init/1' and the first dispatch is a real append.
with_store(Body) ->
    evoq_test_isolation:stop_leftover_evoq(),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(_Store, _Stream, Version, _Events) -> {ok, Version} end),
    {ok, Started} = application:ensure_all_started(evoq),
    try
        Body()
    after
        lists:foreach(fun application:stop/1, lists:reverse(Started)),
        meck:unload(evoq_event_store)
    end.
