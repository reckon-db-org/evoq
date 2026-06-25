%% @doc Partition supervisor for stateful decision actors (Part B).
%%
%% simple_one_for_one over evoq_decision_actor, mirroring
%% evoq_aggregate_partition_sup. Actors are temporary: they passivate
%% on idle and restart on demand via the registry.
%%
%% @author rgfaber
-module(evoq_decision_partition_sup).
-behaviour(supervisor).

%% API
-export([start_link/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start a partition supervisor with the given (registered) name.
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

    ActorSpec = #{
        id => evoq_decision_actor,
        start => {evoq_decision_actor, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [evoq_decision_actor]
    },

    {ok, {SupFlags, [ActorSpec]}}.
