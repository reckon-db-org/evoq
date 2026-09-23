%% @doc A process manager that reacts to every event with one command.
%% The command is built without an aggregate_id so evoq_command:validate/1
%% refuses it before it reaches any router: the test observes the
%% dispatch ATTEMPT (evoq_pm_instance emits [evoq, process_manager,
%% command] telemetry for each), and needs no aggregate to exist.
%% One instance per probe run, so every event reaches the same instance.
-module(evoq_replay_probe_pm).
-behaviour(evoq_process_manager).

-include("evoq.hrl").

-export([interested_in/0, correlate/2, handle/3, apply/2]).

interested_in() -> [<<"replay_probe_v1">>].
correlate(_Event, _Metadata) -> {continue, <<"replay-probe">>}.
handle(State, #{data := #{n := N}}, Metadata) ->
    evoq_replay_probe:record(pm_handle, N, Metadata),
    {ok, State, [#evoq_command{command_type = replay_probe,
                               aggregate_type = replay_probe,
                               payload = #{n => N}}]}.
apply(State, #{data := #{n := N}}) ->
    evoq_replay_probe:record(pm_apply, N, #{}),
    State.
