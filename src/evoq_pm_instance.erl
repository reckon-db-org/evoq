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
    PMState = case erlang:function_exported(PMModule, init, 1) of
        true ->
            case PMModule:init(ProcessId) of
                {ok, S} -> S;
                _ -> #{}
            end;
        false ->
            #{}
    end,

    %% Register with PM router
    EventTypes = PMModule:interested_in(),
    lists:foreach(fun(EventType) ->
        evoq_pm_router:register_instance(EventType, ProcessId, self())
    end, EventTypes),

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

handle_info(_Info, State) ->
    {noreply, State, ?PM_IDLE_TIMEOUT}.

%% @private
terminate(_Reason, #evoq_pm_state{
    pm_module = PMModule,
    process_id = ProcessId
}) ->
    %% Unregister from PM router
    EventTypes = PMModule:interested_in(),
    lists:foreach(fun(EventType) ->
        evoq_pm_router:unregister_instance(EventType, ProcessId)
    end, EventTypes),

    %% Emit stop telemetry
    telemetry:execute(?TELEMETRY_PM_STOP, #{}, #{
        pm_module => PMModule,
        process_id => ProcessId
    }),
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
handle_event_internal(Event, Metadata, #evoq_pm_state{
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

%% @private
dispatch_commands(Commands, #evoq_pm_state{pm_module = PMModule, process_id = ProcessId}) ->
    lists:map(fun(Command) ->
        %% Emit command telemetry
        telemetry:execute(?TELEMETRY_PM_COMMAND, #{}, #{
            pm_module => PMModule,
            process_id => ProcessId,
            command_type => Command#evoq_command.command_type
        }),

        %% Dispatch via router
        case evoq_router:dispatch(Command) of
            {ok, Version, Events} ->
                {ok, Version, Events};
            {error, Reason} ->
                %% Command failed - might need compensation
                logger:warning("PM ~p:~p command failed: ~p",
                    [PMModule, ProcessId, Reason]),
                {error, Reason}
        end
    end, Commands).

%% @private
handle_compensation(FailedCommand, #evoq_pm_state{
    pm_module = PMModule,
    process_id = ProcessId,
    state = PMState
}) ->
    case erlang:function_exported(PMModule, compensate, 2) of
        true ->
            case PMModule:compensate(PMState, FailedCommand) of
                {ok, CompensatingCommands} ->
                    %% Emit compensation telemetry
                    telemetry:execute(?TELEMETRY_PM_COMPENSATE, #{
                        command_count => length(CompensatingCommands)
                    }, #{
                        pm_module => PMModule,
                        process_id => ProcessId
                    }),
                    {ok, CompensatingCommands};
                skip ->
                    skip
            end;
        false ->
            skip
    end.
