%% @doc Top-level supervisor for evoq.
%%
%% Supervises:
%% - evoq_aggregates_sup: Partitioned aggregate supervision
%% - evoq_event_handler_sup: Event handler workers
%% - evoq_pm_sup: Process manager instances
%% - evoq_subscription_manager: reckon-db subscription management
%%
%% @author rgfaber
-module(evoq_sup).
-behaviour(supervisor).

%% API
-export([start_link/0]).

%% Supervisor callbacks
-export([init/1]).

-define(SERVER, ?MODULE).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the top-level supervisor.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    supervisor:start_link({local, ?SERVER}, ?MODULE, []).

%%====================================================================
%% Supervisor callbacks
%%====================================================================

%% @private
-spec init([]) -> {ok, {supervisor:sup_flags(), [supervisor:child_spec()]}}.
init([]) ->
    SupFlags = #{
        strategy => one_for_one,
        intensity => 10,
        period => 60
    },

    Children = [
        %% Idempotency store (must start first)
        worker_child(evoq_idempotency),
        %% Dead letter store
        worker_child(evoq_dead_letter),
        %% Checkpoint store for projections
        worker_child(evoq_checkpoint_store_ets),
        %% Aggregate supervision tree
        supervisor_child(evoq_aggregates_sup),
        %% Stateful decision-actor supervision tree (Part B)
        supervisor_child(evoq_decisions_sup),
        %% Event handler supervision tree
        supervisor_child(evoq_event_handler_sup),
        %% Process manager supervision tree
        supervisor_child(evoq_pm_sup)
    ],

    {ok, {SupFlags, Children}}.

%% A permanent worker started by Module:start_link/0.
worker_child(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => 5000,
        type => worker,
        modules => [Module]
    }.

%% A permanent child supervisor started by Module:start_link/0.
supervisor_child(Module) ->
    #{
        id => Module,
        start => {Module, start_link, []},
        restart => permanent,
        shutdown => infinity,
        type => supervisor,
        modules => [Module]
    }.
