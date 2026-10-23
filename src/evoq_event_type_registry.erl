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
%% == Registrants ==
%%
%% A registrant is a handler process (event handler or projection), joined
%% to one pg group per event type, or a process manager module, registered
%% by the PM router with register_process_manager/2 and held in this
%% process's state. Every registration is announced to the store
%% subscriptions on this node as `{new_registrant, Registrant, Types, Info}',
%% so each one backfills that registrant's history to it alone (evoq #4). A
%% process manager is a registrant of its own: a type only a process manager
%% consumes is routed like any other (evoq #2).
%%
%% Info carries the registrant's `identity', which outlives the process (a
%% handler's module; a process manager's `{pm, Module}'), so a restarted
%% handler is recognised as the same consumer and is not handed again as new
%% what its last incarnation already had; and `from', the global position its
%% history starts at (a projection's checkpoint plus one), so a backfill does
%% not read and route what it already holds.
%%
%% @author rgfaber
-module(evoq_event_type_registry).
-behaviour(gen_server).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([register/2, register_all/2, register_all/3, unregister/2]).
-export([register_process_manager/2, unregister_process_manager/1]).
-export([register_handler/2, unregister_handler/2]).
%% Module registration never stored anything and answered ok (evoq #3); both
%% refuse now and go in 2.0.0.
-deprecated([{register_handler, 2, "start a handler with evoq_event_handler:start_link/2"},
             {unregister_handler, 2, "stop the handler process instead"}]).
-export([get_handlers/1, get_process_managers/1]).
-export([get_all_event_types/0]).
-export([register_listener/1, unregister_listener/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(PG_SCOPE, evoq_event_types).

%% Process manager module => the event types it is interested in, and each
%% registered handler process => its identity (monitored, so a dead one
%% leaves).
-record(state, {
    process_managers = #{} :: #{module() => [binary()]},
    identities = #{} :: #{pid() => identity()}
}).

-type registrant() :: pid() | {pm, module()}.
-type identity() :: term().
-type registration_opts() :: #{identity => identity(), from => non_neg_integer()}.
-export_type([registrant/0, identity/0, registration_opts/0]).

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
%% Store subscription listeners get ONE `{new_registrant, HandlerPid, Types}'
%% message naming every type of the registration, whether or not another
%% handler already holds it, so each subscription backfills the history of
%% those types to this handler alone, in one pass, in global order (evoq #4).
%% Registering types one by one made one backfill per type, and a projection
%% that checkpoints on the global position then skipped every event of its
%% second type below the first type's last one.
-spec register_all([binary()], pid()) -> ok.
register_all(EventTypes, HandlerPid) ->
    register_all(EventTypes, HandlerPid, #{}).

%% @doc register_all/2 with the registrant's identity and starting point.
%%
%% `identity' names the consumer across restarts (default: the pid itself,
%% which never restarts); evoq_event_handler and evoq_projection pass their
%% module. `from' is the global position the registrant's history starts at
%% (default 0); evoq_projection passes its checkpoint plus one.
-spec register_all([binary()], pid(), registration_opts()) -> ok.
register_all(EventTypes, HandlerPid, Opts) ->
    gen_server:call(?SERVER, {register_all, EventTypes, HandlerPid, Opts}).

%% @doc Unregister a handler pid from an event type.
-spec unregister(binary(), pid()) -> ok.
unregister(EventType, HandlerPid) ->
    gen_server:call(?SERVER, {unregister, EventType, HandlerPid}).

%% @doc Register a process manager module for its event types.
%%
%% Called by the PM router. The module becomes a registrant of its own,
%% `{pm, Module}': store subscriptions route its types to the PM router for
%% it whether or not a handler consumes them (evoq #2), and backfill their
%% history to it alone. Registering again replaces its types.
-spec register_process_manager(module(), [binary()]) -> ok.
register_process_manager(Module, EventTypes) ->
    gen_server:call(?SERVER, {register_process_manager, Module, EventTypes}).

%% @doc Withdraw a process manager module.
-spec unregister_process_manager(module()) -> ok.
unregister_process_manager(Module) ->
    gen_server:call(?SERVER, {unregister_process_manager, Module}).

%% @doc Refused: {error, not_supported}. A module is never registered as
%% a handler; start one with evoq_event_handler:start_link/2 (evoq #3).
-spec register_handler(binary(), atom()) -> {error, not_supported}.
register_handler(_EventType, _HandlerModule) ->
    {error, not_supported}.

%% @doc Refused: {error, not_supported}. A module is never registered as
%% a handler; start one with evoq_event_handler:start_link/2 (evoq #3).
-spec unregister_handler(binary(), atom()) -> {error, not_supported}.
unregister_handler(_EventType, _HandlerModule) ->
    {error, not_supported}.

%% @doc The handler processes registered for an event type (pg members).
-spec get_handlers(binary()) -> [pid()].
get_handlers(EventType) ->
    gen_server:call(?SERVER, {get_handlers, EventType}).

%% @doc The process manager modules registered for an event type.
-spec get_process_managers(binary()) -> [module()].
get_process_managers(EventType) ->
    gen_server:call(?SERVER, {get_process_managers, EventType}).

%% @doc Every event type something consumes: a handler or a process
%% manager.
-spec get_all_event_types() -> [binary()].
get_all_event_types() ->
    gen_server:call(?SERVER, get_all_event_types).

%% @doc Register a store subscription listener.
%%
%% Atomically returns every registration that exists now, as
%% `{Registrant, Types}', AND subscribes the listener for every later one.
%% This is race-free: no registration can execute between returning the
%% current ones and subscribing for notifications, because both happen in
%% the same gen_server call. Only registrants on this node are returned and
%% announced: a remote handler is served by its own node's subscription.
%%
%% Each registration is `{Registrant, Types, Identity}'. The listener
%% receives `{new_registrant, Registrant, Types, #{identity, from}}' for
%% every later registration (see register_all/3 and
%% register_process_manager/2) and `{registrant_left, Registrant, Types}'
%% when one withdraws.
-spec register_listener(pid()) -> {ok, [{registrant(), [binary()], identity()}]}.
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
handle_call({register_all, EventTypes, HandlerPid, Opts}, _From,
            #state{identities = Identities} = State) ->
    Types = lists:usort(EventTypes),
    lists:foreach(fun(EventType) -> join_group(EventType, HandlerPid) end, Types),
    Identity = maps:get(identity, Opts, HandlerPid),
    notify_listeners({new_registrant, HandlerPid, Types,
                      #{identity => Identity, from => maps:get(from, Opts, 0)}}),
    {reply, ok, State#state{identities = identify(HandlerPid, Identity, Identities)}};

handle_call({unregister, EventType, HandlerPid}, _From, State) ->
    Group = event_type_group(EventType),
    %% pg:leave returns ok | not_joined - both are acceptable
    _ = pg:leave(?PG_SCOPE, Group, HandlerPid),
    notify_listeners({registrant_left, HandlerPid, [EventType]}),
    {reply, ok, State};

handle_call({register_process_manager, Module, EventTypes}, _From,
            #state{process_managers = PMs} = State) ->
    Types = lists:usort(EventTypes),
    notify_listeners({new_registrant, {pm, Module}, Types,
                      #{identity => {pm, Module}, from => 0}}),
    {reply, ok, State#state{process_managers = PMs#{Module => Types}}};

handle_call({unregister_process_manager, Module}, _From,
            #state{process_managers = PMs} = State) ->
    notify_listeners({registrant_left, {pm, Module}, maps:get(Module, PMs, [])}),
    {reply, ok, State#state{process_managers = maps:remove(Module, PMs)}};

handle_call({get_process_managers, EventType}, _From,
            #state{process_managers = PMs} = State) ->
    {reply, [M || {M, Types} <- maps:to_list(PMs), lists:member(EventType, Types)], State};

handle_call({get_handlers, EventType}, _From, State) ->
    Group = event_type_group(EventType),
    Handlers = pg:get_members(?PG_SCOPE, Group),
    {reply, Handlers, State};

handle_call(get_all_event_types, _From, #state{process_managers = PMs} = State) ->
    Groups = pg:which_groups(?PG_SCOPE),
    HandlerTypes = [extract_event_type(G) || G <- Groups, is_event_type_group(G)],
    {reply, lists:usort(HandlerTypes ++ lists:append(maps:values(PMs))), State};

handle_call({register_listener, ListenerPid}, _From, State) ->
    %% Add listener to notification group
    ok = pg:join(?PG_SCOPE, store_subscription_listeners, ListenerPid),
    %% Return the current registrations atomically (same gen_server call)
    {reply, {ok, registrations(State)}, State};

handle_call({unregister_listener, ListenerPid}, _From, State) ->
    _ = pg:leave(?PG_SCOPE, store_subscription_listeners, ListenerPid),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private A registered handler process died: forget its identity.
handle_info({'DOWN', _Ref, process, Pid, _Reason}, #state{identities = Identities} = State) ->
    {noreply, State#state{identities = maps:remove(Pid, Identities)}};

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

%% @private Join HandlerPid to EventType's group.
join_group(EventType, HandlerPid) ->
    ok = pg:join(?PG_SCOPE, event_type_group(EventType), HandlerPid).

%% @private Remember a handler process's identity, monitoring it once.
identify(Pid, Identity, Identities) when is_map_key(Pid, Identities) ->
    Identities#{Pid => Identity};
identify(Pid, Identity, Identities) ->
    _ = erlang:monitor(process, Pid),
    Identities#{Pid => Identity}.

%% @private Every registration on this node, as {Registrant, Types,
%% Identity}: each local handler pid with the types it holds, and each
%% process manager.
registrations(#state{process_managers = PMs, identities = Identities}) ->
    Pairs = [{Pid, extract_event_type(G)}
             || G <- pg:which_groups(?PG_SCOPE), is_event_type_group(G),
                Pid <- lists:usort(pg:get_local_members(?PG_SCOPE, G))],
    Handlers = maps:to_list(maps:groups_from_list(fun({P, _}) -> P end,
                                                  fun({_, T}) -> T end, Pairs)),
    [{Pid, Types, maps:get(Pid, Identities, Pid)} || {Pid, Types} <- Handlers] ++
        [{{pm, M}, Types, {pm, M}} || {M, Types} <- maps:to_list(PMs)].

%% @private Tell the store subscriptions on this node about a registration
%% or a withdrawal. The listener group is cluster-wide (one pg scope), but a
%% subscription serves the handlers and process managers of its own node:
%% the router skips remote pids, and the process managers live in each
%% node's own PM router.
notify_listeners({_, _, []}) ->
    ok;
notify_listeners(Message) ->
    Listeners = pg:get_local_members(?PG_SCOPE, store_subscription_listeners),
    lists:foreach(fun(Pid) -> Pid ! Message end, Listeners).
