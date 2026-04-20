%% @doc Minimal aggregate used by the dispatch_command slice.
%%
%% Trivial state, one command type, one event type. Just enough
%% surface for the dispatcher to do its full middleware + execution
%% + event-persistence flow. The shape mirrors
%% `evoq_aggregate_registry_test_agg' from the evoq test suite.
-module(bench_agg).

-behaviour(evoq_aggregate).

-compile({no_auto_import, [apply/2]}).

-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) ->
    {ok, #{count => 0}}.

%% evoq_aggregate invokes execute/2 with (State, Command#evoq_command.payload).
%% Emit an event whose `data' IS the payload, so paired comparisons against
%% the bare-storage slice write the SAME event size and the delta measures
%% framework overhead instead of free-riding on an empty payload.
execute(_State, Payload) when is_map(Payload) ->
    {ok, [#{event_type => <<"bench_appended_v1">>, data => Payload}]};
execute(_State, _Payload) ->
    {ok, [#{event_type => <<"bench_appended_v1">>, data => #{}}]}.

apply(#{count := C} = State, _Event) ->
    State#{count => C + 1}.
