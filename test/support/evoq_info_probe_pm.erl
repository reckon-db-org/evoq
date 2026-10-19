%% @doc A process manager that schedules a message to itself, the shape of
%% a clock deadline, and records what reaches its handle_info/2.
%% The command it dispatches from handle_info/2 carries no aggregate_id, so
%% evoq_command:validate/1 refuses it before it reaches any router: the
%% test observes the dispatch ATTEMPT (evoq_pm_instance emits
%% [evoq, process_manager, command] telemetry for each), and needs no
%% aggregate to exist.
-module(evoq_info_probe_pm).
-behaviour(evoq_process_manager).

-include("evoq.hrl").

-export([interested_in/0, correlate/2, handle/3, apply/2]).
-export([handle_info/2]).

interested_in() -> [].
correlate(_Event, _Metadata) -> false.
handle(State, _Event, _Metadata) -> {ok, State}.
apply(State, _Event) -> State.

handle_info({deadline, GameId}, State) ->
    Cmd = #evoq_command{command_type = info_probe_flag,
                        aggregate_type = info_probe,
                        payload = #{game => GameId}},
    {noreply, State#{deadline => GameId}, [Cmd]};
handle_info({quiet, Note}, State) ->
    {noreply, State#{note => Note}};
handle_info(stop_please, State) ->
    {stop, normal, State}.
