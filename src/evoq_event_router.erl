%% @doc Routes events to handlers by event type.
%%
%% Receives events from reckon-db subscriptions and routes them
%% to interested handlers based on event type.
%%
%% Key features:
%% - Per-event-type routing (not per-stream)
%% - Event upcasting before delivery
%% - Parallel delivery to multiple handlers
%% - Telemetry for observability
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

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).

-record(state, {}).

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
    route_event_internal(Event, Metadata, Opts),
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
route_event_internal(Event, Metadata, _Opts) ->
    EventType = maps:get(event_type, Event, undefined),
    case EventType of
        undefined ->
            ok;
        Type ->
            %% Apply upcasting if needed
            {UpcastedEvent, UpcastedType} = upcast_event(Event, Type, Metadata),

            %% Emit routing telemetry
            telemetry:execute(?TELEMETRY_ROUTING_EVENT, #{}, #{
                event_type => UpcastedType,
                original_type => Type
            }),

            %% Get handlers for this event type
            Handlers = evoq_event_type_registry:get_handlers(UpcastedType),

            %% Route to each handler
            route_to_handlers(Handlers, UpcastedType, UpcastedEvent, Metadata)
    end.

%% @private
route_to_handlers(Handlers, Type, Event, Metadata) ->
    lists:foreach(fun(Handler) -> notify_handler(Handler, Type, Event, Metadata) end,
                  Handlers).

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
notify_handler(Handler, EventType, Event, Metadata) when is_pid(Handler), node(Handler) =:= node() ->
    %% Local handler pid - check alive before notifying
    notify_if_alive(is_process_alive(Handler), Handler, EventType, Event, Metadata);
notify_handler(Handler, _EventType, _Event, _Metadata) when is_pid(Handler) ->
    %% Remote handler pid — skip (belongs to another node)
    ok;
notify_handler(Handler, EventType, Event, Metadata) when is_atom(Handler) ->
    %% Handler is a module - call directly (legacy support)
    try
        Handler:handle_event(EventType, Event, Metadata, undefined)
    catch
        _:Reason ->
            logger:warning("Failed to call handler ~p: ~p", [Handler, Reason])
    end.

%% @private Notify a local handler pid only if still alive.
notify_if_alive(true, Handler, EventType, Event, Metadata) ->
    try
        evoq_event_handler:notify(Handler, EventType, Event, Metadata)
    catch
        _:Reason ->
            logger:warning("Failed to notify handler ~p: ~p", [Handler, Reason])
    end;
notify_if_alive(false, _Handler, _EventType, _Event, _Metadata) ->
    ok.
