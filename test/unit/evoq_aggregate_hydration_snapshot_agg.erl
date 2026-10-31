%% @doc Aggregate fixture that can be loaded FROM A SNAPSHOT.
%%
%% `evoq_aggregate_registry_test_agg` exports no `from_snapshot/1', so
%% `try_load_snapshot/3' answers `{error, not_found}' for it and every load
%% takes the replay-from-zero path. A stream with a snapshot resumes its replay
%% through `replayed_or_fresh/3' instead, which is a separate clause and is the
%% path a long-lived stream -- the kind that holds a revocation -- normally
%% takes. This fixture exists to reach that clause.
-module(evoq_aggregate_hydration_snapshot_agg).

-behaviour(evoq_aggregate).

-compile({no_auto_import, [apply/2]}).

-export([state_module/0, init/1, execute/2, apply/2,
         snapshot/1, from_snapshot/1]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{status => active, from => init}}.

execute(_State, #{command_type := test}) ->
    {ok, [#{event_type => <<"test_event_v1">>, data => #{}}]};
execute(_State, _) ->
    {error, unknown_command}.

apply(State, _Event) ->
    State.

snapshot(State) ->
    State.

from_snapshot(Data) ->
    Data.
