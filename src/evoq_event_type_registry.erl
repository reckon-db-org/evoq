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
-export([register/2, register_all/2, unregister/2]).
-export([register_interest/2, unregister_interest/2, has_consumers/1]).
-export([register_handler/2, unregister_handler/2]).
-export([get_handlers/1]).
-export([get_all_event_types/0]).
-export([register_listener/1, unregister_listener/1]).

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

%% @doc Register a handler pid for an event type. Same as
%% `register_all([EventType], HandlerPid)'.
-spec register(binary(), pid()) -> ok.
register(EventType, HandlerPid) ->
    register_all([EventType], HandlerPid).

%% @doc Register a handler pid for all its event types in one step.
%%
%% Store subscription listeners get ONE `{new_event_types, Types}' message
%% naming every type in EventTypes that had no handler before, so a handler
%% registering after catch-up is backfilled in one pass over the store, in
%% global order. Registering its types one by one made one backfill per
%% type, and a projection that checkpoints on the global position then
%% skipped every event of its second type below the first type's last one.
-spec register_all([binary()], pid()) -> ok.
register_all(EventTypes, HandlerPid) ->
    gen_server:call(?SERVER, {register_all, EventTypes, HandlerPid}).

%% @doc Register Pid's interest in EventTypes without making it a handler.
%%
%% For consumers the event router must not deliver to, above all the PM
%% router, which routes events to process manager instances itself. An
%% interest counts wherever the store subscription asks whether a type has
%% a consumer (has_consumers/1, the catch-up snapshot, backfill), but not in
%% get_handlers/1. Types that had neither a handler nor an interest before
%% are announced to store subscription listeners in one {new_event_types, _}
%% message, exactly as a handler's register_all/2 announces them.
-spec register_interest([binary()], pid()) -> ok.
register_interest(EventTypes, Pid) ->
    gen_server:call(?SERVER, {register_interest, EventTypes, Pid}).

%% @doc Withdraw Pid's interest in EventTypes.
-spec unregister_interest([binary()], pid()) -> ok.
unregister_interest(EventTypes, Pid) ->
    gen_server:call(?SERVER, {unregister_interest, EventTypes, Pid}).

%% @doc Whether anything consumes EventType: a handler or an interest.
%% What the store subscription routes on.
-spec has_consumers(binary()) -> boolean().
has_consumers(EventType) ->
    pg:get_members(?PG_SCOPE, event_type_group(EventType)) =/= [] orelse
        pg:get_members(?PG_SCOPE, interest_group(EventType)) =/= [].

%% @doc Unregister a handler pid from an event type.
-spec unregister(binary(), pid()) -> ok.
unregister(EventType, HandlerPid) ->
    gen_server:call(?SERVER, {unregister, EventType, HandlerPid}).

%% @doc Refused: {error, not_supported}. A module is never registered as
%% a handler; start one with evoq_event_handler:start_link/2 (evoq #3).
-spec register_handler(binary(), atom()) -> {error, not_supported}.
register_handler(EventType, HandlerModule) ->
    gen_server:call(?SERVER, {register_module, EventType, HandlerModule}).

%% @doc Refused: {error, not_supported}. A module is never registered as
%% a handler; start one with evoq_event_handler:start_link/2 (evoq #3).
-spec unregister_handler(binary(), atom()) -> {error, not_supported}.
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

%% @doc Register a store subscription listener.
%%
%% Atomically returns the current list of event types AND subscribes
%% the listener for future type registration notifications.
%% This is race-free: no register/2 call can execute between
%% returning the current types and subscribing for notifications,
%% because both happen in the same gen_server call.
%%
%% The listener receives `{new_event_types, EventTypes :: [binary()]}' when
%% a handler registers types that had no handler before (see
%% register_all/2).
-spec register_listener(pid()) -> {ok, [binary()]}.
register_listener(ListenerPid) ->
    gen_server:call(?SERVER, {register_listener, ListenerPid}).

%% @doc Unregister a store subscription listener.
-spec unregister_listener(pid()) -> ok.
unregister_listener(ListenerPid) ->
    gen_server:call(?SERVER, {unregister_listener, ListenerPid}).

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
handle_call({register_all, EventTypes, HandlerPid}, _From, State) ->
    NewTypes = [EventType || EventType <- lists:usort(EventTypes),
                             join_group(event_type_group(EventType), EventType, HandlerPid)],
    notify_listeners(NewTypes),
    {reply, ok, State};

handle_call({register_interest, EventTypes, Pid}, _From, State) ->
    NewTypes = [EventType || EventType <- lists:usort(EventTypes),
                             join_group(interest_group(EventType), EventType, Pid)],
    notify_listeners(NewTypes),
    {reply, ok, State};

handle_call({unregister_interest, EventTypes, Pid}, _From, State) ->
    lists:foreach(fun(T) -> _ = pg:leave(?PG_SCOPE, interest_group(T), Pid) end, EventTypes),
    {reply, ok, State};

handle_call({unregister, EventType, HandlerPid}, _From, State) ->
    Group = event_type_group(EventType),
    %% pg:leave returns ok | not_joined - both are acceptable
    _ = pg:leave(?PG_SCOPE, Group, HandlerPid),
    {reply, ok, State};

%% Module registration never stored anything and answered ok, so a caller
%% believed a module registered that would never receive an event (evoq
%% #3). It refuses; a handler is a process started with
%% evoq_event_handler:start_link/2, which registers itself.
handle_call({register_module, _EventType, _HandlerModule}, _From, State) ->
    {reply, {error, not_supported}, State};

handle_call({unregister_module, _EventType, _HandlerModule}, _From, State) ->
    {reply, {error, not_supported}, State};

handle_call({get_handlers, EventType}, _From, State) ->
    Group = event_type_group(EventType),
    Handlers = pg:get_members(?PG_SCOPE, Group),
    {reply, Handlers, State};

handle_call(get_all_event_types, _From, State) ->
    {reply, consumed_types(), State};

handle_call({register_listener, ListenerPid}, _From, State) ->
    %% Add listener to notification group
    ok = pg:join(?PG_SCOPE, store_subscription_listeners, ListenerPid),
    %% Return current types atomically (same gen_server call): every type
    %% with a handler or an interest, the types catch-up routes.
    {reply, {ok, consumed_types()}, State};

handle_call({unregister_listener, ListenerPid}, _From, State) ->
    _ = pg:leave(?PG_SCOPE, store_subscription_listeners, ListenerPid),
    {reply, ok, State};

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

%% @private The group of pids interested in EventType without being its
%% handlers (see register_interest/2).
interest_group(EventType) ->
    {interest, EventType}.

%% @private Every type with a handler or an interest, once each.
consumed_types() ->
    lists:usort([T || G <- pg:which_groups(?PG_SCOPE), {ok, T} <- [consumed_type(G)]]).

consumed_type({event_type, T}) -> {ok, T};
consumed_type({interest, T}) -> {ok, T};
consumed_type(_) -> none.

%% @private Join Pid to Group; true when EventType had no consumer at all
%% before, neither a handler nor an interest: its first consumer ever.
join_group(Group, EventType, Pid) ->
    IsNew = not has_consumers(EventType),
    ok = pg:join(?PG_SCOPE, Group, Pid),
    IsNew.

%% @private Notify store subscription listeners about new event types, in
%% one message.
notify_listeners([]) ->
    ok;
notify_listeners(NewTypes) ->
    Listeners = pg:get_members(?PG_SCOPE, store_subscription_listeners),
    lists:foreach(fun(Pid) -> Pid ! {new_event_types, NewTypes} end, Listeners).
