%% @doc pg-based registry for stateful decision actors (Part B).
%%
%% Mirrors evoq_aggregate_registry, but keyed on {decision, Module, Key}
%% and in its OWN pg scope (evoq_decision_pg) — kept separate from the
%% aggregate scope for clarity (proposal open-question 1 = "separate").
%%
%% Like the aggregate registry, lookup is node-local: each node may hold
%% its own actor for the same boundary. Cluster-wide correctness comes
%% from reckon-db's append condition, not from the actor being unique.
%%
%% @author rgfaber
-module(evoq_decision_registry).
-behaviour(gen_server).

%% API
-export([start_link/0]).
-export([register/3, unregister/2, lookup/2, get_or_start/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, evoq_decision_pg).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the decision registry (and its pg scope).
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register a decision actor for {Module, Key}.
-spec register(module(), binary(), pid()) -> ok.
register(Module, Key, Pid) ->
    pg:join(?PG_SCOPE, group(Module, Key), Pid).

%% @doc Unregister a decision actor for {Module, Key}.
-spec unregister(module(), binary()) -> ok.
unregister(Module, Key) ->
    case lookup(Module, Key) of
        {ok, Pid} -> pg:leave(?PG_SCOPE, group(Module, Key), Pid);
        {error, not_found} -> ok
    end.

%% @doc Look up the node-local actor for {Module, Key}.
-spec lookup(module(), binary()) -> {ok, pid()} | {error, not_found}.
lookup(Module, Key) ->
    case pg:get_members(?PG_SCOPE, group(Module, Key)) of
        [] -> {error, not_found};
        Pids -> find_alive_local(Pids)
    end.

%% @doc Get the existing actor for {Module, Key} or start one.
-spec get_or_start(module(), binary(), atom()) ->
    {ok, pid()} | {error, term()}.
get_or_start(Module, Key, StoreId) ->
    case lookup(Module, Key) of
        {ok, Pid} ->
            {ok, Pid};
        {error, not_found} ->
            start(Module, Key, StoreId)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private The registry owns its pg scope (vertical slice): start it
%% here so the decision subsystem is self-contained.
init([]) ->
    case pg:start_link(?PG_SCOPE) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    {ok, #{}}.

%% @private
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
%% Internal
%%====================================================================

group(Module, Key) -> {decision, Module, Key}.

%% Node-local + alive, same rule as the aggregate registry: actors must
%% run on the node that owns the store.
find_alive_local([]) ->
    {error, not_found};
find_alive_local([Pid | Rest]) when node(Pid) =:= node() ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> find_alive_local(Rest)
    end;
find_alive_local([_ | Rest]) ->
    find_alive_local(Rest).

start(Module, Key, StoreId) ->
    case evoq_decisions_sup:start_decision(Module, Key, StoreId) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        {error, _} = Error -> Error
    end.
