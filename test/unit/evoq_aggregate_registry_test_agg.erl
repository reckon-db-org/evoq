%% @doc Minimal aggregate for registry race condition tests.
-module(evoq_aggregate_registry_test_agg).

-behaviour(evoq_aggregate).

-compile({no_auto_import, [apply/2]}).

-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{status => active}}.

execute(_State, #{command_type := test}) ->
    {ok, [#{event_type => <<"test_event_v1">>, data => #{}}]};
execute(_State, _) ->
    {error, unknown_command}.

apply(State, _Event) ->
    State.
