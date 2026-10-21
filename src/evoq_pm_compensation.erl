%% @doc Recording what a process manager dispatched, for compensation.
%%
%% == The one compensation contract ==
%%
%% When a command a process manager dispatched fails, its instance calls the
%% module's compensate/2 with the state and the failed command, and
%% dispatches the commands that returns. compensate/2 answers
%% {ok, Commands} or skip.
%%
%% There is no second, per-executed-command form: an earlier
%% build_compensation_chain/2 described one, nothing called it, and two
%% contracts for one word is how a framework teaches the wrong thing.
%%
%% What this module is for is the other half: the list of commands that did
%% run, so a compensate/2 (or an operator looking at get_state/1) can see
%% what there is to undo. The instance records each successful dispatch here
%% when the process manager exports compensate/2; a process manager that
%% does not is left alone.
%%
%% @author rgfaber
-module(evoq_pm_compensation).

-include("evoq.hrl").

-export([record_command/2]).
-export([get_executed_commands/1]).
-export([clear/1]).

%% @doc Record a dispatched command in the process manager's state.
%%
%% Most recent first. State that is not a map is returned unchanged: only a
%% process manager keeps its state in a map, and this must never break one
%% that does not.
-spec record_command(#evoq_command{}, term()) -> term().
record_command(Command, State) when is_map(State) ->
    ExecutedCommands = maps:get(executed_commands, State, []),
    State#{executed_commands => [Command | ExecutedCommands]};
record_command(_Command, State) ->
    State.

%% @doc Every command this process manager dispatched, most recent first.
%%
%% **In memory only.** It is not part of the event stream and does not
%% survive a restart: after one, the list is empty until the instance
%% dispatches again. A `compensate/2' that must work across a restart keeps
%% what it needs in its own state, rebuilt in `apply/2'.
-spec get_executed_commands(term()) -> [#evoq_command{}].
get_executed_commands(State) when is_map(State) ->
    maps:get(executed_commands, State, []);
get_executed_commands(_State) ->
    [].

%% @doc Forget what was dispatched.
%%
%% Called after a compensation has run and when the instance stops: the list
%% is a record of what is still un-undone, not a log that grows for the life
%% of the process manager.
-spec clear(term()) -> term().
clear(State) when is_map(State) ->
    maps:remove(executed_commands, State);
clear(State) ->
    State.
