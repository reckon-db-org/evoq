%%% @doc An aggregate's state is the same however often its stream is replayed.
%%%
%%% apply/2 runs once when execute/2 produces an event, and again on every later
%%% load: a full replay in stream version order, or from_snapshot/1 followed by
%%% the events after the snapshot. State derived from anything but State and
%%% Event (a clock, I/O, process state) comes out different each time.
%%%
%%% The fixture is guides/aggregates.md's account aggregate. Its opened_at
%%% comes from the event's data, which execute/2 fills. The guide used to read
%%% the clock inside apply/2; evoq_replay_clock_account keeps that version so a
%%% test shows what it does.
%%%
%%% The mocked store follows reckon_db's read semantics: read(_, _, Start,
%%% Count, forward) returns versions Start .. Start + Count - 1.
%%% @end
-module(evoq_aggregate_replay_determinism_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2, snapshot/1, from_snapshot/1]).

%%====================================================================
%% Aggregate fixture: the guide's account, with opened_at in the event
%%====================================================================

state_module() -> ?MODULE.

init(AccountId) ->
    {ok, #{account_id => AccountId, balance => 0, opened_at => undefined, status => new}}.

execute(#{status := new}, #{command_type := open_account, initial_deposit := Amount,
                            opened_at := OpenedAt}) ->
    {ok, [#{event_type => <<"AccountOpened">>,
            data => #{initial_deposit => Amount, opened_at => OpenedAt}},
          #{event_type => <<"MoneyDeposited">>, data => #{amount => Amount}}]};
execute(#{status := active, balance := Balance}, #{command_type := withdraw, amount := Amount})
  when Amount =< Balance ->
    {ok, [#{event_type => <<"MoneyWithdrawn">>, data => #{amount => Amount}}]}.

apply(State, #{event_type := <<"AccountOpened">>, data := Data}) ->
    State#{status => active,
           opened_at => maps:get(opened_at, Data),
           initial_deposit => maps:get(initial_deposit, Data)};
apply(#{balance := Balance} = State, #{event_type := <<"MoneyDeposited">>, data := #{amount := A}}) ->
    State#{balance => Balance + A};
apply(#{balance := Balance} = State, #{event_type := <<"MoneyWithdrawn">>, data := #{amount := A}}) ->
    State#{balance => Balance - A}.

snapshot(State) -> State.
from_snapshot(Data) -> Data.

%%====================================================================
%% Tests
%%====================================================================

%% The events as execute/2 produced them, versioned as the store holds them.
stream() ->
    {ok, State0} = init(<<"acc-1">>),
    {ok, Opened} = execute(State0, #{command_type => open_account, initial_deposit => 100,
                                     opened_at => 1_788_000_000_000}),
    State1 = lists:foldl(fun(E, S) -> apply(S, E) end, State0, Opened),
    {ok, Withdrawn} = execute(State1, #{command_type => withdraw, amount => 30}),
    Events = Opened ++ Withdrawn,
    [E#{version => V} || {E, V} <- lists:zip(Events, lists:seq(0, length(Events) - 1))].

%% The state execute-then-apply built live, before anything was stored.
live_state() ->
    {ok, State0} = init(<<"acc-1">>),
    lists:foldl(fun(E, S) -> apply(S, E) end, State0, stream()).

two_replays_of_one_stream_agree_test_() ->
    with_stream(?MODULE, stream(), none, fun() ->
        {First, 2} = evoq_aggregate:load_or_init(?MODULE, <<"acc-1">>, s),
        timer:sleep(5),
        {Second, 2} = evoq_aggregate:load_or_init(?MODULE, <<"acc-1">>, s),
        ?assertEqual(First, Second)
    end).

a_replay_rebuilds_the_state_execute_and_apply_built_test_() ->
    with_stream(?MODULE, stream(), none, fun() ->
        {Replayed, 2} = evoq_aggregate:load_or_init(?MODULE, <<"acc-1">>, s),
        ?assertEqual(live_state(), Replayed),
        ?assertEqual(1_788_000_000_000, maps:get(opened_at, Replayed))
    end).

%% A snapshot after event 0, then events 1 and 2 on top of it: the first
%% apply/2 of this load runs on a from_snapshot/1 state, mid-stream.
a_snapshot_and_its_tail_rebuild_the_same_state_test_() ->
    [Opened | _] = stream(),
    {ok, State0} = init(<<"acc-1">>),
    Snapshot = snapshot(apply(State0, Opened)),
    with_stream(?MODULE, stream(), {0, Snapshot}, fun() ->
        {FromSnapshot, 2} = evoq_aggregate:load_or_init(?MODULE, <<"acc-1">>, s),
        ?assertEqual(live_state(), FromSnapshot)
    end).

%% The guide's old example read the clock in apply/2: every load gives the
%% account a different opening time.
reading_the_clock_in_apply_makes_every_replay_different_test_() ->
    with_stream(evoq_replay_clock_account, stream(), none, fun() ->
        {First, 2} = evoq_aggregate:load_or_init(evoq_replay_clock_account, <<"acc-1">>, s),
        timer:sleep(5),
        {Second, 2} = evoq_aggregate:load_or_init(evoq_replay_clock_account, <<"acc-1">>, s),
        ?assertNotEqual(maps:get(opened_at, First), maps:get(opened_at, Second))
    end).

%%====================================================================
%% The store
%%====================================================================

with_stream(_Module, Events, Snapshot, Test) ->
    {setup,
     fun() ->
         meck:new(evoq_event_store, [passthrough]),
         meck:expect(evoq_event_store, read,
                     fun(_Store, _Stream, Start, Count, forward) ->
                         {ok, [E || #{version := V} = E <- Events,
                                    V >= Start, V =< Start + Count - 1]}
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
