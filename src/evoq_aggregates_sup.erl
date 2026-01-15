%% @doc Supervisor for aggregate processes.
%%
%% Implements partitioned supervision for aggregates. Uses 4 partition
%% supervisors to distribute load and prevent single-supervisor bottlenecks.
%%
%% Aggregates are distributed across partitions using phash2(StreamId, 4).
%%
%% @author rgfaber
-module(evoq_aggregates_sup).
-behaviour(supervisor).

-include("evoq.hrl").

%% API
-export([start_link/0]).
-export([start_aggregate/2, start_aggregate/3, get_aggregate/1, partition_for/1]).

%% Supervisor callbacks
-export([init/1]).

-define(NUM_PARTITIONS, 4).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the aggregates supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start an aggregate process in the appropriate partition (uses env store_id).
%%
%% @deprecated Use start_aggregate/3 with explicit store_id instead.
-spec start_aggregate(atom(), binary()) -> {ok, pid()} | {error, term()}.
start_aggregate(AggregateModule, AggregateId) ->
    StoreId = application:get_env(evoq, store_id, default_store),
    start_aggregate(AggregateModule, AggregateId, StoreId).

%% @doc Start an aggregate process in the appropriate partition with explicit store_id.
-spec start_aggregate(atom(), binary(), atom()) -> {ok, pid()} | {error, term()}.
start_aggregate(AggregateModule, AggregateId, StoreId) ->
    Partition = partition_for(AggregateId),
    PartitionSup = partition_sup_name(Partition),
    supervisor:start_child(PartitionSup, [AggregateModule, AggregateId, StoreId]).

%% @doc Get an existing aggregate process.
-spec get_aggregate(binary()) -> {ok, pid()} | {error, not_found}.
get_aggregate(AggregateId) ->
    evoq_aggregate_registry:lookup(AggregateId).

%% @doc Calculate partition for an aggregate ID.
-spec partition_for(binary()) -> 1..?NUM_PARTITIONS.
partition_for(AggregateId) ->
    erlang:phash2(AggregateId, ?NUM_PARTITIONS) + 1.

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

    %% Start the registry and memory monitor
    Registry = #{
        id => evoq_aggregate_registry,
        start => {evoq_aggregate_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_aggregate_registry]
    },

    MemoryMonitor = #{
        id => evoq_memory_monitor,
        start => {evoq_memory_monitor, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_memory_monitor]
    },

    %% Create partition supervisors
    PartitionSups = [partition_sup_spec(N) || N <- lists:seq(1, ?NUM_PARTITIONS)],

    {ok, {SupFlags, [Registry, MemoryMonitor | PartitionSups]}}.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
partition_sup_name(N) ->
    list_to_atom("evoq_aggregate_partition_sup_" ++ integer_to_list(N)).

%% @private
partition_sup_spec(N) ->
    Name = partition_sup_name(N),
    #{
        id => Name,
        start => {evoq_aggregate_partition_sup, start_link, [Name]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [evoq_aggregate_partition_sup]
    }.
