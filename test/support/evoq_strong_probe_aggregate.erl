%% @doc An aggregate that emits one event of a type a probe handler
%% subscribes to, for the strong consistency tests.
-module(evoq_strong_probe_aggregate).
-behaviour(evoq_aggregate).

-export([state_module/0, init/1, execute/2, apply/2]).

state_module() -> ?MODULE.

init(_AggregateId) -> {ok, #{}}.

execute(_State, #{command_type := <<"emit_strong_probe">>}) ->
    {ok, [#{event_type => <<"strong_probe_v1">>, marker => <<"one">>}]};
execute(_State, #{command_type := <<"emit_quiet_probe">>}) ->
    {ok, [#{event_type => <<"quiet_probe_v1">>, marker => <<"one">>}]};
%% Two events of DIFFERENT types, each with a handler of its own: one append,
%% two handlers, two versions. A `strong' dispatch waits for each at its own.
execute(_State, #{command_type := <<"emit_two_probes">>}) ->
    {ok, [#{event_type => <<"strong_probe_v1">>, marker => <<"one">>},
          #{event_type => <<"other_probe_v1">>, marker => <<"two">>}]};
%% The event a cascade appends: the same type its own handler subscribes to.
execute(_State, #{command_type := <<"emit_cascade_probe">>}) ->
    {ok, [#{event_type => <<"strong_probe_v1">>, marker => <<"cascade">>}]};
execute(_State, _Command) ->
    {error, unknown_command}.

apply(State, _Event) -> State.
