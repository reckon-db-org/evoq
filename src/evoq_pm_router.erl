%% @doc Routes events to process manager instances.
%%
%% Correlates events with process manager instances based on
%% the correlate/2 callback and routes them accordingly.
%%
%% == Correlation Flow ==
%%
%% 1. Event received
%% 2. Find all PM modules interested in this event type
%% 3. For each PM, call correlate/2 to determine process instance
%% 4. Route to existing instance or start new one
%%
%% @author rgfaber
-module(evoq_pm_router).
-behaviour(gen_server).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([route_event/2]).
-export([register_pm/1, unregister_pm/1]).
-export([register_instance/3, unregister_instance/2]).
-export([get_instance/2]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PG_SCOPE, evoq_pm_instances).

-record(state, {
    %% Map of event_type => [pm_module]
    pm_by_event_type = #{} :: #{binary() => [atom()]}
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the PM router.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Route an event to process manager instances.
-spec route_event(map(), map()) -> ok.
route_event(Event, Metadata) ->
    gen_server:cast(?SERVER, {route, Event, Metadata}).

%% @doc Register a process manager module.
-spec register_pm(atom()) -> ok.
register_pm(PMModule) ->
    gen_server:call(?SERVER, {register_pm, PMModule}).

%% @doc Unregister a process manager module.
-spec unregister_pm(atom()) -> ok.
unregister_pm(PMModule) ->
    gen_server:call(?SERVER, {unregister_pm, PMModule}).

%% @doc Register a PM instance for an event type.
-spec register_instance(binary(), binary(), pid()) -> ok.
register_instance(EventType, ProcessId, Pid) ->
    Group = instance_group(EventType, ProcessId),
    case pg:start(?PG_SCOPE) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    ok = pg:join(?PG_SCOPE, Group, Pid).

%% @doc Unregister a PM instance.
-spec unregister_instance(binary(), binary()) -> ok.
unregister_instance(EventType, ProcessId) ->
    Group = instance_group(EventType, ProcessId),
    case pg:get_members(?PG_SCOPE, Group) of
        [] -> ok;
        Members ->
            lists:foreach(fun(Pid) ->
                _ = pg:leave(?PG_SCOPE, Group, Pid)
            end, Members)
    end,
    ok.

%% @doc Get a PM instance by event type and process ID.
-spec get_instance(binary(), binary()) -> {ok, pid()} | {error, not_found}.
get_instance(EventType, ProcessId) ->
    Group = instance_group(EventType, ProcessId),
    case pg:get_members(?PG_SCOPE, Group) of
        [Pid | _] -> {ok, Pid};
        [] -> {error, not_found}
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Start pg scope for PM instances
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    {ok, #state{}}.

%% @private
handle_call({register_pm, PMModule}, _From, #state{pm_by_event_type = Map} = State) ->
    EventTypes = PMModule:interested_in(),
    NewMap = lists:foldl(fun(EventType, Acc) ->
        PMs = maps:get(EventType, Acc, []),
        Acc#{EventType => lists:usort([PMModule | PMs])}
    end, Map, EventTypes),
    {reply, ok, State#state{pm_by_event_type = NewMap}};

handle_call({unregister_pm, PMModule}, _From, #state{pm_by_event_type = Map} = State) ->
    EventTypes = PMModule:interested_in(),
    NewMap = lists:foldl(fun(EventType, Acc) ->
        PMs = maps:get(EventType, Acc, []),
        NewPMs = lists:delete(PMModule, PMs),
        case NewPMs of
            [] -> maps:remove(EventType, Acc);
            _ -> Acc#{EventType => NewPMs}
        end
    end, Map, EventTypes),
    {reply, ok, State#state{pm_by_event_type = NewMap}};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast({route, Event, Metadata}, #state{pm_by_event_type = Map} = State) ->
    EventType = maps:get(event_type, Event, undefined),
    case EventType of
        undefined ->
            ok;
        Type ->
            %% Get all PM modules interested in this event type
            PMModules = maps:get(Type, Map, []),

            %% Route to each PM
            lists:foreach(fun(PMModule) ->
                route_to_pm(PMModule, Event, Metadata)
            end, PMModules)
    end,
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
instance_group(EventType, ProcessId) ->
    {pm_instance, EventType, ProcessId}.

%% @private
route_to_pm(PMModule, Event, Metadata) ->
    %% Correlate event to process instance
    case PMModule:correlate(Event, Metadata) of
        {start, ProcessId} ->
            %% Start new PM instance
            start_and_route(PMModule, ProcessId, Event, Metadata);

        {continue, ProcessId} ->
            %% Route to existing instance or start new
            route_or_start(PMModule, ProcessId, Event, Metadata);

        {stop, ProcessId} ->
            %% Route final event and stop
            route_and_stop(PMModule, ProcessId, Event, Metadata);

        false ->
            %% Event not relevant to this PM
            ok
    end.

%% @private
start_and_route(PMModule, ProcessId, Event, Metadata) ->
    %% Always start a new instance
    case evoq_pm_instance_sup:start_instance(PMModule, ProcessId, #{}) of
        {ok, Pid} ->
            evoq_pm_instance:handle_event(Pid, Event, Metadata);
        {error, Reason} ->
            logger:warning("Failed to start PM instance ~p:~p: ~p",
                [PMModule, ProcessId, Reason])
    end.

%% @private
route_or_start(PMModule, ProcessId, Event, Metadata) ->
    EventType = maps:get(event_type, Event, <<"unknown">>),
    case get_instance(EventType, ProcessId) of
        {ok, Pid} ->
            evoq_pm_instance:handle_event(Pid, Event, Metadata);
        {error, not_found} ->
            %% Start new instance
            start_and_route(PMModule, ProcessId, Event, Metadata)
    end.

%% @private
route_and_stop(_PMModule, ProcessId, Event, Metadata) ->
    EventType = maps:get(event_type, Event, <<"unknown">>),
    case get_instance(EventType, ProcessId) of
        {ok, Pid} ->
            %% Route the final event
            _ = evoq_pm_instance:handle_event(Pid, Event, Metadata),
            %% Stop the instance
            gen_server:stop(Pid);
        {error, not_found} ->
            ok
    end.
