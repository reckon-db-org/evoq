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
        [] ->
            {error, not_found};
        Pids ->
            find_alive_local(Pids)
    end.

%% @private Find the first alive local PID from a list.
%% In a cluster, pg returns PIDs from all nodes. We only want local ones
%% since aggregate processes must run on the node that owns the store.
find_alive_local([]) ->
    {error, not_found};
find_alive_local([Pid | Rest]) when node(Pid) =:= node() ->
    case is_process_alive(Pid) of
        true -> {ok, Pid};
        false -> find_alive_local(Rest)
    end;
find_alive_local([_ | Rest]) ->
    find_alive_local(Rest).

%% @doc Get an existing aggregate or start a new one (uses env store_id).
%%
%% @deprecated Use get_or_start/3 with explicit store_id instead.
-spec get_or_start(atom(), binary()) -> {ok, pid()} | {error, term()}.
get_or_start(AggregateModule, AggregateId) ->
    StoreId = application:get_env(evoq, store_id, default_store),
    get_or_start(AggregateModule, AggregateId, StoreId).

%% @doc Get an existing aggregate or start a new one with explicit store_id.
%%
%% The lookup below is a fast path only. A caller that misses it hands the
%% start to this gen_server, which re-checks before it starts anything.
%%
%% The re-check has to live there because the partition supervisors are
%% simple_one_for_one: start_child always adds another child and can never
%% answer already_started, so two callers that both missed would put two
%% aggregates on one stream. The second would append on the state it read
%% before the first append landed, and a legitimate command would come back
%% as a version conflict. By the time the first start replies, its child has
%% registered itself in init, so the second caller finds it.
-spec get_or_start(atom(), binary(), atom()) -> {ok, pid()} | {error, term()}.
get_or_start(AggregateModule, AggregateId, StoreId) ->
    case lookup(AggregateId) of
        {ok, Pid} ->
            {ok, Pid};
        {error, not_found} ->
            gen_server:call(?MODULE, {get_or_start, AggregateModule, AggregateId, StoreId},
                            infinity)
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Monitor pg for membership changes
    {ok, #{}}.

%% @private The start runs here, one at a time, so the re-check below is a
%% real one: a start this registry has already made has registered its child
%% by the time the previous call replied, so a racing caller finds it instead
%% of starting a second aggregate for the same stream.
handle_call({get_or_start, Module, AggregateId, StoreId}, _From, State) ->
    {reply, get_or_start_serialised(Module, AggregateId, StoreId), State};
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

%% @private Reachable only from handle_call/3 above: nothing else starts an
%% aggregate. There is no already_started clause here on purpose. The
%% partitions are simple_one_for_one, so start_child always starts another
%% child, and a clause handling a reply that cannot come would just hide a
%% partition shape change that needs designing for instead. The registry
%% test asserts no caller ever sees already_started, so such a change fails
%% there rather than in production.
get_or_start_serialised(AggregateModule, AggregateId, StoreId) ->
    case lookup(AggregateId) of
        {ok, Pid} ->
            {ok, Pid};
        {error, not_found} ->
            evoq_aggregates_sup:start_aggregate(AggregateModule, AggregateId, StoreId)
    end.
