%% @doc Saga compensation for rollback transactions.
%%
%% Provides utilities for implementing compensating transactions
%% in process managers (sagas).
%%
%% == Compensation Flow ==
%%
%% 1. Saga dispatches commands: [Cmd1, Cmd2, Cmd3]
%% 2. Cmd3 fails
%% 3. Saga calls compensate/2 for rollback
%% 4. Compensation generates: [Compensate2, Compensate1]
%% 5. Compensating commands executed in reverse order
%%
%% == Example ==
%%
%% ```
%% -module(order_saga).
%% -behaviour(evoq_process_manager).
%%
%% compensate(State, #evoq_command{command_type = ship_order}) ->
%%     %% Compensate shipping by canceling shipment
%%     CancelCmd = evoq_command:new(cancel_shipment, shipping, ...),
%%     {ok, [CancelCmd]};
%%
%% compensate(State, #evoq_command{command_type = charge_payment}) ->
%%     %% Compensate payment by issuing refund
%%     RefundCmd = evoq_command:new(issue_refund, payment, ...),
%%     {ok, [RefundCmd]};
%%
%% compensate(_State, _Cmd) ->
%%     skip.  %% No compensation needed
%% '''
%%
%% @author rgfaber
-module(evoq_saga_compensation).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([execute_compensation/3]).
-export([build_compensation_chain/2]).
-export([record_command/2]).
-export([get_executed_commands/1]).

-define(TABLE, evoq_saga_commands).

%%====================================================================
%% API
%%====================================================================

%% @doc Execute compensation for a failed command.
%% Generates and dispatches compensating commands.
-spec execute_compensation(pid(), #evoq_command{}, map()) ->
    {ok, [{ok, non_neg_integer(), [map()]} | {error, term()}]} | skip.
execute_compensation(PMPid, FailedCommand, Opts) ->
    case evoq_pm_instance:compensate(PMPid, FailedCommand) of
        {ok, CompensatingCommands} ->
            %% Dispatch compensating commands
            Results = dispatch_compensations(CompensatingCommands, Opts),
            {ok, Results};
        skip ->
            skip
    end.

%% @doc Build a chain of compensating commands for all executed commands.
%% Returns commands in reverse order (last executed = first compensated).
-spec build_compensation_chain(atom(), term()) -> [#evoq_command{}].
build_compensation_chain(PMModule, PMState) ->
    compensate_all(get_executed_commands(PMState), PMModule, PMState).

%% @private
compensate_all([], _PMModule, _PMState) ->
    [];
compensate_all(ExecutedCommands, PMModule, PMState) ->
    %% Reverse order: last executed = first compensated.
    ReversedCommands = lists:reverse(ExecutedCommands),
    lists:filtermap(fun(Cmd) -> compensation_for(PMModule, PMState, Cmd) end,
                    ReversedCommands).

%% @private
compensation_for(PMModule, PMState, Cmd) ->
    compensate_cmd(erlang:function_exported(PMModule, compensate, 2),
                   PMModule, PMState, Cmd).

compensate_cmd(true, PMModule, PMState, Cmd) ->
    comp_result(PMModule:compensate(PMState, Cmd));
compensate_cmd(false, _PMModule, _PMState, _Cmd) ->
    false.

comp_result({ok, CompCmds}) -> {true, CompCmds};
comp_result(skip) -> false.

%% @doc Record an executed command in the saga state.
%% Used for tracking commands for compensation.
-spec record_command(#evoq_command{}, term()) -> term().
record_command(Command, State) when is_map(State) ->
    ExecutedCommands = maps:get(executed_commands, State, []),
    State#{executed_commands => [Command | ExecutedCommands]};
record_command(_Command, State) ->
    State.

%% @doc Get all executed commands from saga state.
-spec get_executed_commands(term()) -> [#evoq_command{}].
get_executed_commands(State) when is_map(State) ->
    maps:get(executed_commands, State, []);
get_executed_commands(_State) ->
    [].

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
dispatch_compensations(Commands, Opts) ->
    Timeout = maps:get(timeout, Opts, 5000),
    lists:map(fun(Command) -> dispatch_compensation(Command, Timeout) end, Commands).

%% @private
dispatch_compensation(Command, Timeout) ->
    %% Emit compensation telemetry
    telemetry:execute(?TELEMETRY_PM_COMPENSATE, #{}, #{
        command_type => Command#evoq_command.command_type
    }),
    %% Dispatch with timeout
    comp_dispatch_result(evoq_router:dispatch(Command, #{timeout => Timeout})).

comp_dispatch_result({ok, Version, Events}) ->
    {ok, Version, Events};
comp_dispatch_result({error, Reason}) ->
    logger:error("Compensation command failed: ~p", [Reason]),
    {error, Reason}.
