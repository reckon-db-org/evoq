%% @doc Supervisor for process manager instances.
%%
%% Process managers (sagas) coordinate long-running business processes
%% that span multiple aggregates. Each PM instance is correlated by
%% a process_id derived from event metadata.
%%
%% @author rgfaber
-module(evoq_pm_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_pm_instance/2]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the process manager supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a process manager instance.
-spec start_pm_instance(atom(), binary()) -> {ok, pid()} | {error, term()}.
start_pm_instance(PMModule, ProcessId) ->
    supervisor:start_child(evoq_pm_instance_sup, [PMModule, ProcessId]).

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

    PMRouter = #{
        id => evoq_pm_router,
        start => {evoq_pm_router, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [evoq_pm_router]
    },

    PMInstanceSup = #{
        id => evoq_pm_instance_sup,
        start => {evoq_pm_instance_sup, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [evoq_pm_instance_sup]
    },

    {ok, {SupFlags, [PMRouter, PMInstanceSup]}}.
