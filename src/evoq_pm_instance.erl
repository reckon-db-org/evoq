%% @doc Process manager instance GenServer.
%%
%% Represents a single running instance of a process manager.
%% Each instance:
%% - Has a unique process ID (correlation ID)
%% - Maintains its own state
%% - Handles events and dispatches commands
%% - Supports compensation on a failed command
%%
%% @author rgfaber
-module(evoq_pm_instance).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([start_link/3]).
-export([handle_event/3]).
-export([get_state/1]).
-export([compensate/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PM_IDLE_TIMEOUT, 30000).  %% 30 seconds idle timeout

%%====================================================================
%% API
%%====================================================================

%% @doc Start a PM instance.
-spec start_link(atom(), binary(), map()) -> {ok, pid()} | {error, term()}.
start_link(PMModule, ProcessId, Config) ->
    gen_server:start_link(?MODULE, {PMModule, ProcessId, Config}, []).

%% @doc Handle an event.
%%
%% `{ok, Results}' carries one entry per command the process manager
%% dispatched, in order, plus one per compensating command if a dispatch
%% failed, so the list can be shorter than the commands the PM returned.
-spec handle_event(pid(), map(), map()) ->
    ok
    | {ok, [{ok, non_neg_integer(), [map()]} | {error, term()}]}
    | {error, term()}.
handle_event(Pid, Event, Metadata) ->
    gen_server:call(Pid, {handle_event, Event, Metadata}, infinity).

%% @doc Get the current state.
-spec get_state(pid()) -> {ok, term()}.
get_state(Pid) ->
    gen_server:call(Pid, get_state).

%% @doc Trigger compensation for a failed command.
-spec compensate(pid(), #evoq_command{}) -> {ok, [#evoq_command{}]} | skip.
compensate(Pid, FailedCommand) ->
    gen_server:call(Pid, {compensate, FailedCommand}).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({PMModule, ProcessId, _Config}) ->
    %% Initialize PM state. The module is loaded first (evoq#39): this is the
    %% first thing an instance does, so nothing has called the PM yet, and
    %% `function_exported/3' answers false for a module that is not loaded --
    %% which read as "this PM has no init/1" and started it on the default state
    %% instead of the one its own init/1 returns. The same hazard
    %% `pm_has_info_handler/1' below already guards against.
    _ = code:ensure_loaded(PMModule),
    PMState = init_pm_state(erlang:function_exported(PMModule, init, 1),
                            PMModule, ProcessId),

    %% Register with PM router, as PMModule's instance for ProcessId
    ok = evoq_pm_router:register_instance(PMModule, ProcessId, self()),

    %% Emit start telemetry
    telemetry:execute(?TELEMETRY_PM_START, #{}, #{
        pm_module => PMModule,
        process_id => ProcessId
    }),

    State = #evoq_pm_state{
        pm_module = PMModule,
        process_id = ProcessId,
        state = PMState,
        pending_commands = []
    },
    {ok, State, ?PM_IDLE_TIMEOUT}.

%% @private
handle_call({handle_event, Event, Metadata}, _From, State) ->
    case handle_event_internal(Event, Metadata, State) of
        {ok, NewState, Commands} ->
            %% Dispatch commands, carrying this event's lineage onto them
            {Results, DispatchedState} = dispatch_commands(Commands, Metadata, NewState),
            {reply, {ok, Results}, DispatchedState, ?PM_IDLE_TIMEOUT};
        {ok, NewState} ->
            {reply, ok, NewState, ?PM_IDLE_TIMEOUT};
        {error, Reason} ->
            {reply, {error, Reason}, State, ?PM_IDLE_TIMEOUT}
    end;

handle_call(get_state, _From, #evoq_pm_state{state = PMState} = State) ->
    {reply, {ok, PMState}, State, ?PM_IDLE_TIMEOUT};

handle_call({compensate, FailedCommand}, _From, State) ->
    Result = handle_compensation(FailedCommand, State),
    {reply, Result, State, ?PM_IDLE_TIMEOUT};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, ?PM_IDLE_TIMEOUT}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State, ?PM_IDLE_TIMEOUT}.

%% @private
handle_info(timeout, #evoq_pm_state{pm_module = PMModule, process_id = ProcessId} = State) ->
    %% Idle timeout - could passivate or continue
    logger:debug("PM instance ~p:~p idle timeout", [PMModule, ProcessId]),
    {noreply, State, ?PM_IDLE_TIMEOUT};

%% @private Everything else goes to the process manager module. This used
%% to drop every message, so a PM that scheduled one to itself (a clock
%% deadline via send_after, the reason this callback exists) never saw it
%% and the deadline never fired. The atom `timeout' is matched above: it is
%% evoq's own idle timer, not a message for the PM.
handle_info(Info, #evoq_pm_state{pm_module = PMModule} = State) ->
    forward_info(pm_has_info_handler(PMModule), Info, State).

%% @private
terminate(_Reason, #evoq_pm_state{
    pm_module = PMModule,
    process_id = ProcessId
}) ->
    %% Unregister from PM router
    evoq_pm_router:unregister_instance(PMModule, ProcessId, self()),

    %% Emit stop telemetry
    telemetry:execute(?TELEMETRY_PM_STOP, #{}, #{
        pm_module => PMModule,
        process_id => ProcessId
    }),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private A PM that exports handle_info/2 handles its own messages. One
%% that does not is named, with the message, rather than losing it quietly:
%% that silence is what hid the gap this callback closes.
%%
%% The module is loaded first: function_exported/3 answers false for a
%% module that is not loaded yet, and an instance can be sent a message
%% before it has handled its first event (nothing else would have loaded
%% it), which would read as "no handle_info/2" for a PM that has one.
pm_has_info_handler(PMModule) ->
    _ = code:ensure_loaded(PMModule),
    erlang:function_exported(PMModule, handle_info, 2).

forward_info(true, Info, #evoq_pm_state{pm_module = PMModule, state = PMState} = State) ->
    info_result(PMModule:handle_info(Info, PMState), PMModule, State);
forward_info(false, Info, #evoq_pm_state{pm_module = PMModule} = State) ->
    logger:warning(#{what => evoq_pm_has_no_handle_info,
                     pm => PMModule,
                     message => Info}),
    {noreply, State, ?PM_IDLE_TIMEOUT}.

%% @private Commands returned from handle_info/2 are dispatched exactly as
%% the ones from handle/3 are, so a deadline can be a command without the
%% PM reaching for a router of its own.
info_result({noreply, NewPMState}, _PMModule, State) ->
    {noreply, State#evoq_pm_state{state = NewPMState}, ?PM_IDLE_TIMEOUT};
info_result({noreply, NewPMState, Commands}, _PMModule, State) when is_list(Commands) ->
    %% A self-scheduled message has no triggering event, so there is no
    %% lineage to carry: #{}. A PM that wants its deadline commands in its
    %% conversation sets the ids on the command itself.
    {_Results, DispatchedState} = dispatch_commands(Commands, #{},
                                                    State#evoq_pm_state{state = NewPMState}),
    {noreply, DispatchedState, ?PM_IDLE_TIMEOUT};
info_result({stop, Reason, NewPMState}, _PMModule, State) ->
    {stop, Reason, State#evoq_pm_state{state = NewPMState}};
info_result(Other, PMModule, _State) ->
    error({bad_handle_info_return, PMModule, Other}).

%% @private Replay (`replaying => true': an event this node had already
%% consumed before it restarted) still runs through handle/3 and apply/2,
%% so a process manager rebuilds exactly the state it had, including state
%% it keeps in handle/3 (the state-machine pattern does). What replay does
%% NOT do is dispatch: the process manager already reacted to this event,
%% and dispatching the commands again re-issued its whole history on every
%% restart. handle/3 sees `replaying => true' in Metadata, so a process
%% manager with a side effect of its own can tell as well.
handle_event_internal(Event, Metadata, State) ->
    drop_replayed_commands(maps:get(replaying, Metadata, false),
                           react(Event, Metadata, State)).

drop_replayed_commands(true, {ok, NewState, _AlreadyDispatched}) -> {ok, NewState};
drop_replayed_commands(_Replaying, Result) -> Result.

react(Event, Metadata, #evoq_pm_state{
    pm_module = PMModule,
    state = PMState
} = State) ->
    %% Call the PM's handle callback
    case PMModule:handle(PMState, Event, Metadata) of
        {ok, NewPMState} ->
            %% Apply the event to update state
            AppliedState = PMModule:apply(NewPMState, Event),
            {ok, State#evoq_pm_state{state = AppliedState}};

        {ok, NewPMState, Commands} when is_list(Commands) ->
            %% Apply the event to update state
            AppliedState = PMModule:apply(NewPMState, Event),
            {ok, State#evoq_pm_state{state = AppliedState}, Commands};

        {error, Reason} ->
            {error, Reason}
    end.

%% @private Initialise PM state from the optional init/1 callback.
init_pm_state(true, PMModule, ProcessId) ->
    pm_init_result(PMModule:init(ProcessId));
init_pm_state(false, _PMModule, _ProcessId) ->
    #{}.

pm_init_result({ok, S}) -> S;
pm_init_result(_) -> #{}.

%% @private
dispatch_commands(Commands, Metadata, State) ->
    dispatch_in_order(Commands, Metadata, State, []).

%% @private Commands run in the order the PM returned them, and stop at the
%% first one that fails: a process manager whose third step failed must not run its
%% fourth. Each success is recorded in the PM's state, so a compensation can
%% see what actually ran (evoq_pm_compensation:get_executed_commands/1
%% reads it back), and the failure is compensated through the PM's own
%% compensate/2.
%%
%% Until this was wired the failure was only logged, and process_managers.md
%% described a rollback that never happened.
dispatch_in_order([], _Metadata, State, Acc) ->
    {lists:reverse(Acc), State};
dispatch_in_order([Command | Rest], Metadata,
                  #evoq_pm_state{pm_module = PMModule, process_id = ProcessId} = State,
                  Acc) ->
    Stamped = stamp_lineage(Command, Metadata),
    case dispatch_pm_command(Stamped, PMModule, ProcessId) of
        {ok, _Version, _Events} = Ok ->
            dispatch_in_order(Rest, Metadata, record_dispatched(Stamped, State), [Ok | Acc]);
        {error, Reason} = Error ->
            {Compensated, CompensatedState} =
                compensate_after_failure(Stamped, Reason, Metadata, State),
            {lists:reverse([Error | Acc]) ++ Compensated, CompensatedState}
    end.

%% @private Only a process manager that declared compensate/2 has its
%% dispatches recorded: a PM that never opted into compensation is not given
%% a key in its own state it did not ask for, and does not accumulate one
%% forever. A compensating PM gets the list `compensate/2' and
%% evoq_pm_compensation:get_executed_commands/1 read.
record_dispatched(Command, #evoq_pm_state{pm_module = PMModule, state = PMState} = State) ->
    State#evoq_pm_state{state = record_if_compensating(PMModule, Command, PMState)}.

%% @private
%%
%% No ensure_loaded here (evoq#39): this runs when a command is dispatched from
%% a PM instance, and an instance starts by calling its module's `init/1' -- or,
%% since that was fixed, by being loaded to find out whether it has one. Either
%% way the module is loaded before the first dispatch. `init/1' and
%% `pm_has_info_handler/1' above are the two that run at cold time, and both
%% load it themselves.
record_if_compensating(PMModule, Command, PMState) ->
    record_result(erlang:function_exported(PMModule, compensate, 2),
                  Command, PMState).

record_result(true, Command, PMState) ->
    evoq_pm_compensation:record_command(Command, PMState);
record_result(false, _Command, PMState) ->
    PMState.

%% @private
compensate_after_failure(Command, Reason, Metadata,
                         #evoq_pm_state{process_id = ProcessId} = State) ->
    case handle_compensation(Command, State) of
        {ok, CompensatingCommands} ->
            logger:warning("PM ~p: command failed (~p); compensating with ~p command(s)",
                           [ProcessId, Reason, length(CompensatingCommands)]),
            {[dispatch_compensation(C, Metadata) || C <- CompensatingCommands],
             forget_dispatched(State)};
        skip ->
            logger:warning("PM ~p: command failed (~p); no compensation",
                           [ProcessId, Reason]),
            {[], forget_dispatched(State)}
    end.

%% @private The transaction is over: what ran has been undone, or nobody
%% asked for it to be. Starting the list again keeps it a record of what is
%% still outstanding rather than a log that grows for the life of the
%% process manager.
forget_dispatched(#evoq_pm_state{state = PMState} = State) ->
    State#evoq_pm_state{state = evoq_pm_compensation:clear(PMState)}.

%% @private A compensating command is still the PM responding to the same
%% event, so it carries the same lineage as the command that failed. It
%% went out bare at first, which put the undo in a conversation of its own.
dispatch_compensation(Command, Metadata) ->
    compensation_dispatch_result(evoq_router:dispatch(stamp_lineage(Command, Metadata)),
                                 Command).

%% @private A compensating command that fails is logged rather than raised:
%% the transaction is already unwinding, and stopping the instance would
%% lose the record of what it did run.
compensation_dispatch_result({ok, _Version, _Events} = Ok, _Command) ->
    Ok;
compensation_dispatch_result({error, Reason} = Error, Command) ->
    logger:error("PM compensation command ~p failed: ~p",
                 [Command#evoq_command.command_type, Reason]),
    Error.

%% @private Carry the conversation across the process-manager hop (EIP
%% Causation Id, Hohpe and Woolf; GY-AW Causation Id chapter). The PM is a
%% responder: the commands it issues copy the triggering event's
%% correlation_id forward, and name that event as their cause. Without this
%% every hop started a new conversation - evoq_command:new/4,5 mints a fresh
%% correlation_id and leaves causation_id undefined - so a chain
%% aggregate -> event -> PM -> command -> event lost both ids that make
%% "how did I get here?" answerable.
%%
%% Both are only set when the PM has not set them itself. The command a PM
%% returns carries no correlation unless the PM put one there (see
%% evoq_command:ensure_id/1: the router mints one at dispatch, never the
%% constructor), so:
%%
%%   - a PM that returns a plain command inherits the triggering event's
%%     conversation, which is the pattern: copy the correlation id of the
%%     message you are responding to onto the new messages;
%%   - a PM that calls evoq_command:set_correlation_id/2 deliberately starts
%%     a new conversation, and keeps it. That is the explicit opt-out, and
%%     it is explicit because the id is there before dispatch.
stamp_lineage(Command, Metadata) when is_map(Metadata) ->
    Command#evoq_command{
        causation_id = first_defined(Command#evoq_command.causation_id,
                                     maps:get(event_id, Metadata, undefined)),
        correlation_id = first_defined(Command#evoq_command.correlation_id,
                                       evoq_lineage:correlation_id(Metadata))
    }.

%% @private
first_defined(undefined, Fallback) -> Fallback;
first_defined(Value, _Fallback) -> Value.

dispatch_pm_command(Command, PMModule, ProcessId) ->
    %% Emit command telemetry
    telemetry:execute(?TELEMETRY_PM_COMMAND, #{}, #{
        pm_module => PMModule,
        process_id => ProcessId,
        command_type => Command#evoq_command.command_type
    }),
    pm_dispatch_result(evoq_router:dispatch(Command), PMModule, ProcessId).

pm_dispatch_result({ok, Version, Events}, _PMModule, _ProcessId) ->
    {ok, Version, Events};
pm_dispatch_result({error, Reason}, PMModule, ProcessId) ->
    %% Logged here; the caller compensates (see compensate_after_failure/3).
    logger:warning("PM ~p:~p command failed: ~p", [PMModule, ProcessId, Reason]),
    {error, Reason}.

%% @private
%% No load first, and none needed: this runs from the compensation path of a
%% process this module started, so the PM module's own init/1 has already loaded
%% it. The same reasoning as record_if_compensating/3 above (and evoq#36/#39).
handle_compensation(FailedCommand, #evoq_pm_state{
    pm_module = PMModule,
    process_id = ProcessId,
    state = PMState
}) ->
    compensate_if_exported(erlang:function_exported(PMModule, compensate, 2),
                           PMModule, ProcessId, PMState, FailedCommand).

compensate_if_exported(true, PMModule, ProcessId, PMState, FailedCommand) ->
    compensation_result(PMModule:compensate(PMState, FailedCommand), PMModule, ProcessId);
compensate_if_exported(false, _PMModule, _ProcessId, _PMState, _FailedCommand) ->
    skip.

compensation_result({ok, CompensatingCommands}, PMModule, ProcessId) ->
    telemetry:execute(?TELEMETRY_PM_COMPENSATE, #{
        command_count => length(CompensatingCommands)
    }, #{
        pm_module => PMModule,
        process_id => ProcessId
    }),
    {ok, CompensatingCommands};
compensation_result(skip, _PMModule, _ProcessId) ->
    skip.
