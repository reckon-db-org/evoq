%% @doc Supervisor for process manager instances.
%%
%% Uses simple_one_for_one strategy for dynamic PM instance creation.
%%
%% @author rgfaber
-module(evoq_pm_instance_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).
-export([start_instance/3]).
-export([stop_instance/1]).

%% Supervisor callbacks
-export([init/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the PM instance supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

%% @doc Start a new PM instance.
-spec start_instance(atom(), binary(), map()) -> {ok, pid()} | {error, term()}.
start_instance(PMModule, ProcessId, Config) ->
    supervisor:start_child(?MODULE, [PMModule, ProcessId, Config]).

%% @doc Stop a PM instance.
-spec stop_instance(pid()) -> ok | {error, term()}.
stop_instance(Pid) ->
    supervisor:terminate_child(?MODULE, Pid).

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

    PMSpec = #{
        id => evoq_pm_instance,
        start => {evoq_pm_instance, start_link, []},
        restart => temporary,
        shutdown => 5000,
        type => worker,
        modules => [evoq_pm_instance]
    },

    {ok, {SupFlags, [PMSpec]}}.
