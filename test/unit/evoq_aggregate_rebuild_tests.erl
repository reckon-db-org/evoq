%%% @doc Regression tests for evoq_aggregate:rebuild_from_events/3.
%%%
%%% Exercises the private rebuild_from_events/3 (exposed under TEST)
%%% against a mocked evoq_event_store. The focus is the empty-stream
%%% edge case — rebuild used to report version=0 for a stream with no
%%% events, causing the dispatcher's wrong_expected_version retry loop
%%% to spin against a Ra stream at version=-1 until the retry budget
%%% was exhausted.
%%% @end
-module(evoq_aggregate_rebuild_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Aggregate fixture
%%====================================================================

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{counter => 0}}.

execute(_State, _Command) ->
    {ok, []}.

apply(State, _Event) ->
    State.

%%====================================================================
%% Setup / teardown
%%====================================================================

setup_mock(Events) ->
    meck:new(evoq_event_store, [passthrough]),
    meck:expect(evoq_event_store, read,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, Events} end),
    ok.

teardown_mock(_) ->
    meck:unload(evoq_event_store).

%%====================================================================
%% Tests
%%====================================================================

%% An empty stream must report version = -1, not 0. The dispatcher
%% uses this value as the expected_version for the next append, and
%% appending "expected=0" to a stream at version=-1 fails forever.
rebuild_empty_stream_reports_version_minus_one_test_() ->
    {setup,
     fun() -> setup_mock([]) end,
     fun teardown_mock/1,
     fun() ->
         {ok, State, Version} =
             evoq_aggregate:rebuild_from_events(?MODULE, my_store, <<"agg-1">>),
         ?assertEqual(-1, Version),
         ?assertEqual(#{counter => 0}, State)
     end}.

%% Sanity check: a stream with events must report the last event's
%% version, not FromVersion. Covers the non-empty branch of
%% replay_events so we don't regress it while fixing the empty one.
rebuild_stream_with_events_reports_last_version_test_() ->
    Events = [
        #{event_type => <<"counter_incremented_v1">>,
          data => #{}, version => 0},
        #{event_type => <<"counter_incremented_v1">>,
          data => #{}, version => 1}
    ],
    {setup,
     fun() -> setup_mock(Events) end,
     fun teardown_mock/1,
     fun() ->
         {ok, _State, Version} =
             evoq_aggregate:rebuild_from_events(?MODULE, my_store, <<"agg-1">>),
         ?assertEqual(1, Version)
     end}.

%% If the event store read errors, rebuild propagates the error
%% instead of swallowing it and claiming a version.
rebuild_store_error_propagates_test_() ->
    {setup,
     fun() ->
         meck:new(evoq_event_store, [passthrough]),
         meck:expect(evoq_event_store, read,
                     fun(_Store, _Stream, _From, _Count, _Dir) ->
                         {error, store_down}
                     end)
     end,
     fun teardown_mock/1,
     fun() ->
         Result =
             evoq_aggregate:rebuild_from_events(?MODULE, my_store, <<"agg-1">>),
         ?assertEqual({error, store_down}, Result)
     end}.
