%% @doc Partition supervisor for aggregate processes.
%%
%% Uses simple_one_for_one strategy for dynamic aggregate child creation.
%% Each partition handles approximately 1/4 of all aggregates based on
%% hash distribution.
%%
%% @author rgfaber
-module(evoq_aggregate_partition_sup).
-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a partition supervisor with the given name.
-spec start_link(atom()) -> {ok, pid()} | {error, term()}.
start_link(Name) ->
    supervisor:start_link({local, Name}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% @private
init([]) ->
    SupFlags = #{
        strategy => simple_one_for_one,
        intensity => 100,
        period => 60
    },

    AggregateSpec = #{
        id => evoq_aggregate,
        start => {evoq_aggregate, start_link, []},
        restart => temporary,  %% Aggregates can be passivated and restarted on demand
        shutdown => 5000,
        type => worker,
        modules => [evoq_aggregate]
    },

    {ok, {SupFlags, [AggregateSpec]}}.
