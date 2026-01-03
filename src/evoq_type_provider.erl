%% @doc Type provider for event type to module mapping.
%%
%% Maintains mappings between:
%% - Event types (binary strings) and event modules
%% - Event types and their upcasters
%%
%% This enables:
%% - Dynamic event deserialization
%% - Schema evolution through upcasters
%% - Type-safe event handling
%%
%% @author rgfaber
-module(evoq_type_provider).
-behaviour(gen_server).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([register_event/2, register_upcaster/2]).
-export([get_module/1, get_upcaster/1]).
-export([get_all_types/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE_EVENTS, evoq_type_provider_events).
-define(TABLE_UPCASTERS, evoq_type_provider_upcasters).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the type provider.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Register an event type to module mapping.
-spec register_event(binary(), atom()) -> ok.
register_event(EventType, Module) ->
    gen_server:call(?SERVER, {register_event, EventType, Module}).

%% @doc Register an upcaster for an event type.
-spec register_upcaster(binary(), atom()) -> ok.
register_upcaster(EventType, UpcasterModule) ->
    gen_server:call(?SERVER, {register_upcaster, EventType, UpcasterModule}).

%% @doc Get the module for an event type.
-spec get_module(binary()) -> {ok, atom()} | {error, not_found}.
get_module(EventType) ->
    case ets:lookup(?TABLE_EVENTS, EventType) of
        [{EventType, Module}] -> {ok, Module};
        [] -> {error, not_found}
    end.

%% @doc Get the upcaster for an event type.
-spec get_upcaster(binary()) -> {ok, atom()} | {error, not_found}.
get_upcaster(EventType) ->
    case ets:lookup(?TABLE_UPCASTERS, EventType) of
        [{EventType, Upcaster}] -> {ok, Upcaster};
        [] -> {error, not_found}
    end.

%% @doc Get all registered event types.
-spec get_all_types() -> [binary()].
get_all_types() ->
    [Type || {Type, _} <- ets:tab2list(?TABLE_EVENTS)].

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Create ETS tables for fast lookup
    _ = create_table(?TABLE_EVENTS),
    _ = create_table(?TABLE_UPCASTERS),
    {ok, #state{}}.

%% @private
handle_call({register_event, EventType, Module}, _From, State) ->
    ets:insert(?TABLE_EVENTS, {EventType, Module}),
    {reply, ok, State};

handle_call({register_upcaster, EventType, UpcasterModule}, _From, State) ->
    ets:insert(?TABLE_UPCASTERS, {EventType, UpcasterModule}),
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
create_table(Name) ->
    case ets:whereis(Name) of
        undefined ->
            ets:new(Name, [
                named_table,
                public,
                set,
                {read_concurrency, true}
            ]);
        _Tid ->
            Name
    end.
