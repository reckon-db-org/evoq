%% @doc Routes events to handlers by event type.
%%
%% Receives events from reckon-db subscriptions and routes them
%% to interested handlers based on event type.
%%
%% Key features:
%% - Per-event-type routing (not per-stream)
%% - Event upcasting before delivery
%% - Delivery isolated per handler (see below)
%% - Telemetry for observability
%%
%% == Delivery isolation ==
%%
%% Each local handler process gets its own courier: a process that hands
%% it its events with evoq_event_handler:notify/4, one at a time, in the
%% order the router routed them. The router only passes an event to the
%% courier, so a handler that is slow, blocked, or sleeping out a
%% {retry, DelayMs} backoff delays its own events and nobody else's. Before,
%% the router made that call itself, handler after handler, and one slow
%% handler held up every handler and projection on the node (evoq#30). The
%% handler still acknowledges its own write to a strong-consistency waiter.
%% A courier ends when its handler does.
%%
%% @author rgfaber
-module(evoq_event_router).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([start_link/0]).
-export([route_event/2, route_event/3]).
-export([route_events/2]).
-export([delivery_targets/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {
    %% local handler pid => its courier
    couriers = #{} :: #{pid() => pid()}
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the event router.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Route an event to interested handlers.
-spec route_event(map(), map()) -> ok.
route_event(Event, Metadata) ->
    route_event(Event, Metadata, #{}).

%% @doc Route an event with options.
%%
%% `targets => [pid()]' delivers to exactly those handlers instead of every
%% handler registered for the type. The store subscription uses it: it
%% delivers a store's events only to handlers whose history from that store
%% it has sent, and a late handler's history to that handler alone
%% (evoq #4).
-spec route_event(map(), map(), map()) -> ok.
route_event(Event, Metadata, Opts) ->
    gen_server:cast(?SERVER, {route, Event, Metadata, Opts}).

%% @doc Route multiple events to interested handlers.
-spec route_events([map()], map()) -> ok.
route_events(Events, Metadata) ->
    lists:foreach(fun(Event) ->
        route_event(Event, Metadata)
    end, Events),
    ok.

%% @doc The type this event is delivered as, and the handler processes that
%% delivery reaches.
%%
%% Read from the registry, through the same upcasting the delivery does, so
%% a caller asking "who will see this event" gets the answer the router acts
%% on. `evoq_consistency' asks it to derive what a `strong' dispatch must
%% wait for; nothing keeps a list.
-spec delivery_targets(map()) -> {binary(), [pid()]}.
delivery_targets(#{event_type := Type} = Event) ->
    {_Upcasted, UpcastedType} = upcast_event(Event, Type, #{}),
    {UpcastedType, evoq_event_type_registry:get_handlers(UpcastedType)};
delivery_targets(_Event) ->
    {undefined, []}.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    {ok, #state{}}.

%% @private
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast({route, Event, Metadata, Opts}, State) ->
    {noreply, route_event_internal(Event, Metadata, Opts, State)};

handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info({'DOWN', _Ref, process, Courier, _Reason}, #state{couriers = Couriers} = State) ->
    {noreply, State#state{couriers = maps:filter(fun(_H, C) -> C =/= Courier end, Couriers)}};
handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
route_event_internal(Event, Metadata, Opts, State) ->
    EventType = maps:get(event_type, Event, undefined),
    case EventType of
        undefined ->
            State;
        Type ->
            %% Apply upcasting if needed
            {UpcastedEvent, UpcastedType} = upcast_event(Event, Type, Metadata),

            %% Emit routing telemetry
            telemetry:execute(?TELEMETRY_ROUTING_EVENT, #{}, #{
                event_type => UpcastedType,
                original_type => Type
            }),

            Handlers = handlers(Opts, UpcastedType),

            %% Route to each handler
            route_to_handlers(Handlers, UpcastedType, UpcastedEvent, Metadata, State)
    end.

%% @private The handlers named by the caller, or every handler of the type.
handlers(#{targets := Targets}, _Type) -> Targets;
handlers(_Opts, Type) -> evoq_event_type_registry:get_handlers(Type).

route_to_handlers(Handlers, Type, Event, Metadata, State) ->
    lists:foldl(fun(Handler, Acc) -> notify_handler(Handler, Type, Event, Metadata, Acc) end,
                State, Handlers).

%% @private
upcast_event(Event, EventType, Metadata) ->
    upcast_with(evoq_type_provider:get_upcaster(EventType), Event, EventType, Metadata).

upcast_with({ok, UpcasterModule}, Event, EventType, Metadata) ->
    apply_upcast(UpcasterModule:upcast(Event, Metadata), Event, EventType);
upcast_with({error, not_found}, Event, EventType, _Metadata) ->
    {Event, EventType}.

apply_upcast({ok, UpcastedEvent}, _Event, EventType) ->
    {UpcastedEvent, EventType};
apply_upcast({ok, UpcastedEvent, NewEventType}, _Event, _EventType) ->
    {UpcastedEvent, NewEventType};
apply_upcast(skip, Event, EventType) ->
    {Event, EventType}.

%% @private
notify_handler(Handler, EventType, Event, Metadata, State)
  when is_pid(Handler), node(Handler) =:= node() ->
    %% Local handler pid: its courier delivers, the router moves on
    {Courier, State1} = courier(Handler, State),
    Courier ! {deliver, EventType, Event, Metadata},
    State1;
notify_handler(Handler, _EventType, _Event, _Metadata, State) when is_pid(Handler) ->
    %% Remote handler pid — skip (belongs to another node)
    State;
notify_handler(Handler, EventType, Event, Metadata, State) when is_atom(Handler) ->
    %% Handler is a module - call directly (legacy support)
    try
        Handler:handle_event(EventType, Event, Metadata, undefined)
    catch
        _:Reason ->
            logger:warning("Failed to call handler ~p: ~p", [Handler, Reason])
    end,
    State.

%% @private The handler's courier, started on its first event.
courier(Handler, #state{couriers = Couriers} = State) ->
    courier(maps:find(Handler, Couriers), Handler, State).

courier({ok, Courier}, _Handler, State) ->
    {Courier, State};
courier(error, Handler, #state{couriers = Couriers} = State) ->
    Router = self(),
    {Courier, _Ref} = spawn_monitor(fun() -> start_courier(Router, Handler) end),
    {Courier, State#state{couriers = Couriers#{Handler => Courier}}}.

%% @private A courier ends when its handler does, and with the router: an
%% event left in its mailbox would otherwise be delivered by nobody's
%% courier, out of order with what a restarted router sends.
start_courier(Router, Handler) ->
    link(Router),
    courier_loop(Handler, erlang:monitor(process, Handler)).

courier_loop(Handler, Ref) ->
    receive
        {deliver, EventType, Event, Metadata} ->
            notify_if_alive(is_process_alive(Handler), Handler, EventType, Event, Metadata),
            courier_loop(Handler, Ref);
        {'DOWN', Ref, process, Handler, _Reason} ->
            ok
    end.

%% @private Notify a local handler pid only if still alive.
%%
%% The reply is read rather than discarded: a projection that answered
%% {error, Reason} used to look exactly like one that succeeded, which hid
%% a dropped event. The handler decides what a failure means (retry, skip,
%% dead letter); the router only makes sure a failure that comes back to it
%% leaves a trace.
notify_if_alive(true, Handler, EventType, Event, Metadata) ->
    try
        notify_reply(evoq_event_handler:notify(Handler, EventType, Event, Metadata),
                     Handler, EventType)
    catch
        _:Reason ->
            logger:warning("Failed to notify handler ~p: ~p", [Handler, Reason])
    end;
notify_if_alive(false, _Handler, _EventType, _Event, _Metadata) ->
    ok.

%% @private
notify_reply(ok, _Handler, _EventType) ->
    ok;
notify_reply({error, Reason}, Handler, EventType) ->
    logger:warning(#{what => evoq_handler_returned_error,
                     handler => Handler,
                     event_type => EventType,
                     error => Reason}),
    ok.
