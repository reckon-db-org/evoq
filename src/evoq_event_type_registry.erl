%% @doc Event type registry for evoq.
%%
%% Maintains a mapping of event types to interested handlers.
%% Uses pg (process groups) for efficient pub/sub routing.
%%
%% This is the key to per-event-type subscriptions:
%% - Handlers register interest in specific event types
%% - When events are published, only interested handlers receive them
%% - Scales to millions of events without per-stream overhead
%%
%% @author rgfaber
-module(evoq_event_type_registry).
-behaviour(gen_server).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([register/2, unregister/2]).
-export([register_handler/2, unregister_handler/2]).
-export([get_handlers/1]).
-export([get_all_event_types/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PG_SCOPE, evoq_event_types).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the event type registry.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register a handler pid for an event type.
-spec register(binary(), pid()) -> ok.
register(EventType, HandlerPid) ->
    gen_server:call(?SERVER, {register, EventType, HandlerPid}).

%% @doc Unregister a handler pid from an event type.
-spec unregister(binary(), pid()) -> ok.
unregister(EventType, HandlerPid) ->
    gen_server:call(?SERVER, {unregister, EventType, HandlerPid}).

%% @doc Register a handler module for an event type (legacy API).
-spec register_handler(binary(), atom()) -> ok.
register_handler(EventType, HandlerModule) ->
    gen_server:call(?SERVER, {register_module, EventType, HandlerModule}).

%% @doc Unregister a handler module from an event type (legacy API).
-spec unregister_handler(binary(), atom()) -> ok.
unregister_handler(EventType, HandlerModule) ->
    gen_server:call(?SERVER, {unregister_module, EventType, HandlerModule}).

%% @doc Get all handlers registered for an event type.
%% Returns both pids (from pg) and modules (from internal state).
-spec get_handlers(binary()) -> [pid() | atom()].
get_handlers(EventType) ->
    gen_server:call(?SERVER, {get_handlers, EventType}).

%% @doc Get all registered event types.
-spec get_all_event_types() -> [binary()].
get_all_event_types() ->
    gen_server:call(?SERVER, get_all_event_types).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Start pg scope for event types
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end,
    {ok, #state{}}.

%% @private
handle_call({register, EventType, HandlerPid}, _From, State) ->
    Group = event_type_group(EventType),
    ok = pg:join(?PG_SCOPE, Group, HandlerPid),
    {reply, ok, State};

handle_call({unregister, EventType, HandlerPid}, _From, State) ->
    Group = event_type_group(EventType),
    %% pg:leave returns ok | not_joined - both are acceptable
    _ = pg:leave(?PG_SCOPE, Group, HandlerPid),
    {reply, ok, State};

handle_call({register_module, _EventType, _HandlerModule}, _From, State) ->
    %% Module registration is handled by the handler supervisor
    %% which starts the handler process and calls register/2
    {reply, ok, State};

handle_call({unregister_module, _EventType, _HandlerModule}, _From, State) ->
    {reply, ok, State};

handle_call({get_handlers, EventType}, _From, State) ->
    Group = event_type_group(EventType),
    Handlers = pg:get_members(?PG_SCOPE, Group),
    {reply, Handlers, State};

handle_call(get_all_event_types, _From, State) ->
    Groups = pg:which_groups(?PG_SCOPE),
    Types = [extract_event_type(G) || G <- Groups, is_event_type_group(G)],
    {reply, Types, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
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
event_type_group(EventType) ->
    {event_type, EventType}.

%% @private
is_event_type_group({event_type, _}) -> true;
is_event_type_group(_) -> false.

%% @private
extract_event_type({event_type, EventType}) -> EventType.
