%% @doc Supervisor for the stateful decision-actor subsystem (Part B).
%%
%% Mirrors evoq_aggregates_sup: the decision registry plus N partition
%% supervisors, with actors distributed by phash2({Module, Key}, N).
%% A separate tree from the aggregate one — no shared, hardwired sup is
%% touched (see SPIKE_EVOQ_DECISION_ACTOR.md, Path 1).
%%
%% @author rgfaber
-module(evoq_decisions_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_decision/3, partition_for/1]).

%% Supervisor callbacks
-export([init/1]).

-define(NUM_PARTITIONS, 4).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the decisions supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a decision actor for {Module, Key} in its partition.
-spec start_decision(module(), binary(), atom()) ->
    {ok, pid()} | {error, term()}.
start_decision(Module, Key, StoreId) ->
    Partition = partition_for({Module, Key}),
    PartitionSup = partition_sup_name(Partition),
    supervisor:start_child(PartitionSup, [Module, Key, StoreId]).

%% @doc Partition for a {Module, Key} boundary identity.
-spec partition_for({module(), binary()}) -> 1..?NUM_PARTITIONS.
partition_for(BoundaryId) ->
    erlang:phash2(BoundaryId, ?NUM_PARTITIONS) + 1.

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

    Registry = #{
        id => evoq_decision_registry,
        start => {evoq_decision_registry, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_decision_registry]
    },

    PartitionSups = [partition_sup_spec(N) || N <- lists:seq(1, ?NUM_PARTITIONS)],

    {ok, {SupFlags, [Registry | PartitionSups]}}.

%%====================================================================
%% Internal
%%====================================================================

partition_sup_name(N) ->
    list_to_atom("evoq_decision_partition_sup_" ++ integer_to_list(N)).

partition_sup_spec(N) ->
    Name = partition_sup_name(N),
    #{
        id => Name,
        start => {evoq_decision_partition_sup, start_link, [Name]},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [evoq_decision_partition_sup]
    }.
