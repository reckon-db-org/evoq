%% @doc Process manager instance GenServer.
%%
%% Represents a single running instance of a process manager (saga).
%% Each instance:
%% - Has a unique process ID (correlation ID)
%% - Maintains its own state
%% - Handles events and dispatches commands
%% - Supports saga compensation on failures
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
-spec handle_event(pid(), map(), map()) -> ok | {error, term()}.
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
    %% Initialize PM state
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
            %% Dispatch commands
            Results = dispatch_commands(Commands, State),
            {reply, {ok, Results}, NewState, ?PM_IDLE_TIMEOUT};
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
    _ = dispatch_commands(Commands, State),
    {noreply, State#evoq_pm_state{state = NewPMState}, ?PM_IDLE_TIMEOUT};
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
dispatch_commands(Commands, #evoq_pm_state{pm_module = PMModule, process_id = ProcessId}) ->
    lists:map(fun(Command) -> dispatch_pm_command(Command, PMModule, ProcessId) end,
              Commands).

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
    %% Command failed - might need compensation
    logger:warning("PM ~p:~p command failed: ~p", [PMModule, ProcessId, Reason]),
    {error, Reason}.

%% @private
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
