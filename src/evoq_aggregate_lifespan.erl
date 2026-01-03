%% @doc Behavior for controlling aggregate lifecycle.
%%
%% Aggregates can be configured with different lifespan strategies:
%% - TTL-based: Passivate after idle timeout
%% - Hibernate: Reduce memory footprint when idle
%% - Infinite: Keep alive forever (not recommended)
%%
%% The default implementation (evoq_aggregate_lifespan_default) provides
%% sensible defaults with 30-minute TTL and automatic snapshots.
%%
%% @author rgfaber
-module(evoq_aggregate_lifespan).

-include("evoq.hrl").

%% Lifespan action type
-type action() ::
    timeout() |       %% Timeout in milliseconds
    infinity |        %% No timeout
    hibernate |       %% Enter hibernate mode
    stop |            %% Stop immediately
    passivate.        %% Save snapshot and stop

-export_type([action/0]).

%% Required callbacks
-callback after_event(Event :: map()) -> action().
-callback after_command(Command :: map()) -> action().
-callback after_error(Error :: term()) -> action().

%% Optional callbacks
-callback on_timeout(State :: term()) ->
    {ok, action()} | {snapshot, action()}.
-callback on_passivate(State :: term()) ->
    {ok, SnapshotData :: term()} | skip.
-callback on_activate(StreamId :: binary(), Snapshot :: term() | undefined) ->
    {ok, State :: term()}.

-optional_callbacks([on_timeout/1, on_passivate/1, on_activate/2]).
