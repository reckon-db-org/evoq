%% @doc ETS-based checkpoint store implementation.
%%
%% In-memory checkpoint storage for development and testing.
%% For production, use a persistent implementation (e.g., database-backed).
%%
%% Note: Checkpoints are lost on application restart.
%% Use only for development or projections that can easily rebuild.
%%
%% @author rgfaber
-module(evoq_checkpoint_store_ets).
-behaviour(evoq_checkpoint_store).
-behaviour(gen_server).

%% API
-export([start_link/0]).

%% Behavior callbacks
-export([load/1, save/2, delete/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, evoq_checkpoints).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the checkpoint store.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Load checkpoint for a projection.
-spec load(atom()) -> {ok, non_neg_integer()} | {error, not_found}.
load(ProjectionName) ->
    case ets:lookup(?TABLE, ProjectionName) of
        [{ProjectionName, Checkpoint}] ->
            {ok, Checkpoint};
        [] ->
            {error, not_found}
    end.

%% @doc Save checkpoint for a projection.
-spec save(atom(), non_neg_integer()) -> ok.
save(ProjectionName, Checkpoint) ->
    true = ets:insert(?TABLE, {ProjectionName, Checkpoint}),
    ok.

%% @doc Delete checkpoint for a projection.
-spec delete(atom()) -> ok.
delete(ProjectionName) ->
    true = ets:delete(?TABLE, ProjectionName),
    ok.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Create ETS table for checkpoints
    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),
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
