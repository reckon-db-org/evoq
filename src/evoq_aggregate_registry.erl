%% @doc pg-based registry for aggregate processes.
%%
%% Uses OTP pg module for process registration and lookup.
%% Aggregates register with a group key of {aggregate, AggregateId}.
%%
%% @author rgfaber
-module(evoq_aggregate_registry).
-behaviour(gen_server).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([register/2, unregister/1, lookup/1, get_or_start/2, get_or_start/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(PG_SCOPE, evoq_pg).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the aggregate registry.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Register an aggregate process.
-spec register(binary(), pid()) -> ok.
register(AggregateId, Pid) ->
    pg:join(?PG_SCOPE, {aggregate, AggregateId}, Pid).

%% @doc Unregister an aggregate process.
-spec unregister(binary()) -> ok.
unregister(AggregateId) ->
    case lookup(AggregateId) of
        {ok, Pid} ->
            pg:leave(?PG_SCOPE, {aggregate, AggregateId}, Pid);
        {error, not_found} ->
            ok
    end.

%% @doc Lookup an aggregate by ID.
-spec lookup(binary()) -> {ok, pid()} | {error, not_found}.
lookup(AggregateId) ->
    case pg:get_members(?PG_SCOPE, {aggregate, AggregateId}) of
        [Pid | _] when is_pid(Pid) ->
            case is_process_alive(Pid) of
                true -> {ok, Pid};
                false -> {error, not_found}
            end;
        [] ->
            {error, not_found}
    end.

%% @doc Get an existing aggregate or start a new one (uses env store_id).
%%
%% @deprecated Use get_or_start/3 with explicit store_id instead.
-spec get_or_start(atom(), binary()) -> {ok, pid()} | {error, term()}.
get_or_start(AggregateModule, AggregateId) ->
    StoreId = application:get_env(evoq, store_id, default_store),
    get_or_start(AggregateModule, AggregateId, StoreId).

%% @doc Get an existing aggregate or start a new one with explicit store_id.
-spec get_or_start(atom(), binary(), atom()) -> {ok, pid()} | {error, term()}.
get_or_start(AggregateModule, AggregateId, StoreId) ->
    case lookup(AggregateId) of
        {ok, Pid} ->
            {ok, Pid};
        {error, not_found} ->
            start_aggregate(AggregateModule, AggregateId, StoreId)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Monitor pg for membership changes
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
%% Internal functions
%%====================================================================

%% @private
start_aggregate(AggregateModule, AggregateId, StoreId) ->
    evoq_aggregates_sup:start_aggregate(AggregateModule, AggregateId, StoreId).
