%%% @doc An aggregate stream of any length replays to its last event.
%%%
%%% evoq_aggregate replayed with ONE evoq_event_store:read/5 of 1000 events
%%% and no loop, so a stream longer than 1000 loaded at version 999 and every
%%% command on it failed {wrong_expected_version, 999, N}, forever. Found live
%%% by Saturnus on macula-realm (a 1173-event aggregate). Both the load path
%%% (no snapshot) and the rebuild path went through it.
%%%
%%% Also: after a snapshot at version V (the last event the snapshot holds),
%%% replay started AT V, so event V was applied twice on top of the snapshot.
%%%
%%% The mocked store follows reckon_db's read semantics exactly:
%%% read(_, _, Start, Count, forward) returns the events with versions
%%% Start .. Start + Count - 1 (inclusive), fewer at the end of the stream.
%%% @end
-module(evoq_aggregate_replay_paging_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2,
         snapshot/1, from_snapshot/1]).

%%====================================================================
%% Aggregate fixture: counts every event applied, remembers the last one.
%%====================================================================

state_module() -> ?MODULE.
init(_AggregateId) -> {ok, #{applied => 0, last => none}}.
execute(_State, _Command) -> {ok, []}.
apply(#{applied := N} = S, #{version := V}) -> S#{applied => N + 1, last => V}.
snapshot(State) -> State.
from_snapshot(Data) -> Data.

%%====================================================================
%% Tests
%%====================================================================

rebuild_2500_event_stream_reaches_2499_test_() ->
    with_stream(2500, fun() ->
        {ok, State, Version} = evoq_aggregate:rebuild_from_events(?MODULE, s, <<"a">>),
        ?assertEqual(2499, Version),
        ?assertEqual(#{applied => 2500, last => 2499}, State)
    end).

load_2500_event_stream_reaches_2499_test_() ->
    with_stream(2500, fun() ->
        {State, Version} = evoq_aggregate:load_or_init(?MODULE, <<"a">>, s),
        ?assertEqual(2499, Version),
        ?assertEqual(#{applied => 2500, last => 2499}, State)
    end).

exactly_1000_events_reach_999_test_() ->
    with_stream(1000, fun() ->
        {ok, State, Version} = evoq_aggregate:rebuild_from_events(?MODULE, s, <<"a">>),
        ?assertEqual(999, Version),
        ?assertEqual(1000, maps:get(applied, State))
    end).

exactly_1001_events_reach_1000_test_() ->
    with_stream(1001, fun() ->
        {ok, State, Version} = evoq_aggregate:rebuild_from_events(?MODULE, s, <<"a">>),
        ?assertEqual(1000, Version),
        ?assertEqual(1001, maps:get(applied, State))
    end).

empty_stream_still_reports_minus_one_test_() ->
    with_stream(0, fun() ->
        {ok, _State, Version} = evoq_aggregate:rebuild_from_events(?MODULE, s, <<"a">>),
        ?assertEqual(-1, Version)
    end).

%% A snapshot holding events 0..1499 (version 1499) of a 2500-event stream:
%% exactly events 1500..2499 are applied on top of it, each once.
load_from_snapshot_applies_only_the_events_after_it_test_() ->
    with_stream(2500, {1499, #{applied => 1500, last => 1499}}, fun() ->
        {State, Version} = evoq_aggregate:load_or_init(?MODULE, <<"a">>, s),
        ?assertEqual(2499, Version),
        ?assertEqual(#{applied => 2500, last => 2499}, State)
    end).

%% A snapshot at the stream's last event: nothing to apply, version kept.
load_from_snapshot_at_the_tip_applies_nothing_test_() ->
    with_stream(1200, {1199, #{applied => 1200, last => 1199}}, fun() ->
        {State, Version} = evoq_aggregate:load_or_init(?MODULE, <<"a">>, s),
        ?assertEqual(1199, Version),
        ?assertEqual(#{applied => 1200, last => 1199}, State)
    end).

%% A store that ignores the start version returns the same full page every
%% time. The replay must refuse, not read that page forever.
a_store_that_ignores_the_start_version_is_refused_test_() ->
    {setup,
     fun() ->
         meck:new(evoq_event_store, [passthrough]),
         meck:expect(evoq_event_store, read,
                     fun(_Store, _Stream, _Start, Count, forward) ->
                         {ok, [#{event_type => <<"counted_v1">>, data => #{},
                                 version => V} || V <- lists:seq(0, Count - 1)]}
                     end)
     end,
     fun(_) -> meck:unload(evoq_event_store) end,
     fun() ->
         ?assertMatch({error, {replay_not_advancing, <<"a">>, 999, 999}},
                      evoq_aggregate:rebuild_from_events(?MODULE, s, <<"a">>))
     end}.

%%====================================================================
%% A stream of N events (versions 0..N-1), optionally a snapshot.
%%====================================================================

with_stream(N, Test) -> with_stream(N, none, Test).

with_stream(N, Snapshot, Test) ->
    {setup,
     fun() ->
         meck:new(evoq_event_store, [passthrough]),
         meck:expect(evoq_event_store, read,
                     fun(_Store, _Stream, Start, Count, forward) ->
                         Last = min(Start + Count - 1, N - 1),
                         {ok, [#{event_type => <<"counted_v1">>, data => #{},
                                 version => V} || V <- lists:seq(Start, Last)]}
                     end),
         meck:new(evoq_snapshot_store, [passthrough]),
         meck:expect(evoq_snapshot_store, load,
                     fun(_Store, _Stream) -> snapshot_answer(Snapshot) end)
     end,
     fun(_) ->
         meck:unload(evoq_snapshot_store),
         meck:unload(evoq_event_store)
     end,
     Test}.

snapshot_answer(none) -> {error, not_found};
snapshot_answer({Version, Data}) -> {ok, #{data => Data, version => Version}}.
