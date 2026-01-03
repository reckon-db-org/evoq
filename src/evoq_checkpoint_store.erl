%% @doc Checkpoint store behavior for projections.
%%
%% Provides persistent storage for projection checkpoints.
%% This allows projections to resume from where they left off after restart.
%%
%% == Callbacks ==
%%
%% Required:
%% - load(ProjectionName) -> {ok, Checkpoint} | {error, not_found}
%% - save(ProjectionName, Checkpoint) -> ok | {error, Reason}
%%
%% @author rgfaber
-module(evoq_checkpoint_store).

%% Behavior callbacks
-callback load(ProjectionName :: atom()) ->
    {ok, Checkpoint :: non_neg_integer()} | {error, not_found | term()}.

-callback save(ProjectionName :: atom(), Checkpoint :: non_neg_integer()) ->
    ok | {error, term()}.

%% Optional: delete checkpoint
-callback delete(ProjectionName :: atom()) -> ok | {error, term()}.

-optional_callbacks([delete/1]).
