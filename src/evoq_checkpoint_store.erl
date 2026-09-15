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

%% A checkpoint is an opaque position term. Projections use a
%% non-negative integer version; the checkpointed event handler uses an
%% {Offset, OrderKey} pair. An implementation stores and returns it
%% verbatim.
-type checkpoint() :: term().
-export_type([checkpoint/0]).

%% Behavior callbacks
-callback load(ProjectionName :: atom()) ->
    {ok, Checkpoint :: checkpoint()} | {error, not_found | term()}.

-callback save(ProjectionName :: atom(), Checkpoint :: checkpoint()) ->
    ok | {error, term()}.

%% Optional: delete checkpoint
-callback delete(ProjectionName :: atom()) -> ok | {error, term()}.

-optional_callbacks([delete/1]).
