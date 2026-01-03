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
        #{
            id => evoq_idempotency,
            start => {evoq_idempotency, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [evoq_idempotency]
        },
        %% Dead letter store
        #{
            id => evoq_dead_letter,
            start => {evoq_dead_letter, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [evoq_dead_letter]
        },
        %% Checkpoint store for projections
        #{
            id => evoq_checkpoint_store_ets,
            start => {evoq_checkpoint_store_ets, start_link, []},
            restart => permanent,
            shutdown => 5000,
            type => worker,
            modules => [evoq_checkpoint_store_ets]
        },
        %% Aggregate supervision tree
        #{
            id => evoq_aggregates_sup,
            start => {evoq_aggregates_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [evoq_aggregates_sup]
        },
        %% Event handler supervision tree
        #{
            id => evoq_event_handler_sup,
            start => {evoq_event_handler_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [evoq_event_handler_sup]
        },
        %% Process manager supervision tree
        #{
            id => evoq_pm_sup,
            start => {evoq_pm_sup, start_link, []},
            restart => permanent,
            shutdown => infinity,
            type => supervisor,
            modules => [evoq_pm_sup]
        }
    ],

    {ok, {SupFlags, Children}}.
