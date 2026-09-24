%%% @doc The account aggregate as guides/aggregates.md used to show it: apply/2
%%% reads the clock. Kept for evoq_aggregate_replay_determinism_tests, which
%%% shows that every replay of its stream gives a different state. Do not copy.
-module(evoq_replay_clock_account).

-compile({no_auto_import, [apply/2]}).

-behaviour(evoq_aggregate).
-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(AccountId) ->
    {ok, #{account_id => AccountId, balance => 0, opened_at => undefined, status => new}}.

execute(_State, _Command) -> {ok, []}.

apply(State, #{event_type := <<"AccountOpened">>, data := Data}) ->
    State#{status => active,
           opened_at => erlang:system_time(millisecond),
           initial_deposit => maps:get(initial_deposit, Data)};
apply(#{balance := Balance} = State, #{event_type := <<"MoneyDeposited">>, data := #{amount := A}}) ->
    State#{balance => Balance + A};
apply(#{balance := Balance} = State, #{event_type := <<"MoneyWithdrawn">>, data := #{amount := A}}) ->
    State#{balance => Balance - A}.
