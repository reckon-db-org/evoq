%% @doc Supervisor for event handler workers.
%%
%% Manages event handlers that subscribe to event types (not streams).
%% Each handler declares interest in specific event types via the
%% interested_in/0 callback.
%%
%% @author rgfaber
-module(evoq_event_handler_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_handler/1, start_handler/2]).
-export([stop_handler/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the event handler supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start an event handler worker with default config.
-spec start_handler(atom()) -> {ok, pid()} | {error, term()}.
start_handler(HandlerModule) ->
    start_handler(HandlerModule, #{}).

%% @doc Start an event handler worker with config.
-spec start_handler(atom(), map()) -> {ok, pid()} | {error, term()}.
start_handler(HandlerModule, Config) ->
    ChildSpec = #{
        id => HandlerModule,
        start => {evoq_event_handler, start_link, [HandlerModule, Config]},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_event_handler, HandlerModule]
    },
    supervisor:start_child(?MODULE, ChildSpec).

%% @doc Stop an event handler worker.
-spec stop_handler(atom()) -> ok | {error, term()}.
stop_handler(HandlerModule) ->
    case supervisor:terminate_child(?MODULE, HandlerModule) of
        ok ->
            supervisor:delete_child(?MODULE, HandlerModule);
        Error ->
            Error
    end.

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% @private
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    %% Core services - order matters
    TypeProvider = #{
        id => evoq_type_provider,
        start => {evoq_type_provider, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_type_provider]
    },

    TypeRegistry = #{
        id => evoq_event_type_registry,
        start => {evoq_event_type_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_event_type_registry]
    },

    EventRouter = #{
        id => evoq_event_router,
        start => {evoq_event_router, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_event_router]
    },

    {ok, {SupFlags, [TypeProvider, TypeRegistry, EventRouter]}}.
