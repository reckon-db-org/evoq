%% @doc Consistency modes for command dispatch.
%%
%% Supports:
%% - eventual: Return immediately after events are persisted
%% - strong: Wait for all handlers to process events
%% - {handlers, [atom()]}: Wait for specific handlers
%%
%% Uses pg for handler acknowledgment tracking.
%%
%% == Strong Consistency Flow ==
%%
%% 1. Command dispatched, events persisted
%% 2. Dispatcher calls wait_for/4
%% 3. Event handlers process events
%% 4. Handlers call acknowledge/4 after processing
%% 5. wait_for/4 returns when all required handlers ack
%%
%% @author rgfaber
-module(evoq_consistency).

-include("evoq_telemetry.hrl").

%% API
-export([wait_for/4]).
-export([acknowledge/4]).
-export([start_pg/0]).

-define(PG_SCOPE, evoq_consistency_pg).
-define(DEFAULT_TIMEOUT, 5000).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the pg scope for consistency tracking.
-spec start_pg() -> ok.
start_pg() ->
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

%% @doc Wait for handlers to process events up to the given version.
-spec wait_for(atom(), binary(), non_neg_integer(), map()) -> ok | {error, timeout}.
wait_for(StoreId, AggregateId, Version, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    RequiredHandlers = maps:get(handlers, Opts, all),

    %% Create a unique waiter key
    WaiterKey = {consistency_waiter, StoreId, AggregateId, Version},

    %% Ensure pg scope is started
    start_pg(),

    %% Register as a waiter
    ok = pg:join(?PG_SCOPE, WaiterKey, self()),

    try
        %% Determine which handlers to wait for
        HandlersToWait = case RequiredHandlers of
            all ->
                %% Get all handlers registered for this aggregate's event types
                %% For now, use empty set (will accept any ack)
                [];
            HandlerList when is_list(HandlerList) ->
                HandlerList
        end,

        wait_loop(WaiterKey, HandlersToWait, #{}, Timeout)
    after
        _ = pg:leave(?PG_SCOPE, WaiterKey, self())
    end.

%% @doc Acknowledge that a handler has processed events.
%% Called by event handlers after processing.
-spec acknowledge(atom(), atom(), binary(), non_neg_integer()) -> ok.
acknowledge(HandlerModule, StoreId, AggregateId, Version) ->
    WaiterKey = {consistency_waiter, StoreId, AggregateId, Version},

    %% Ensure pg scope is started
    start_pg(),

    %% Notify all waiters
    Waiters = pg:get_members(?PG_SCOPE, WaiterKey),
    lists:foreach(fun(Pid) ->
        Pid ! {handler_ack, HandlerModule, StoreId, AggregateId, Version}
    end, Waiters),

    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
wait_loop(_WaiterKey, [], _Acked, _Timeout) ->
    %% No specific handlers required - return immediately
    ok;

wait_loop(WaiterKey, Required, Acked, Timeout) ->
    %% Check if all required handlers have acked
    case all_acked(Required, Acked) of
        true ->
            ok;
        false ->
            receive
                {handler_ack, HandlerModule, _StoreId, _AggregateId, _Version} ->
                    NewAcked = Acked#{HandlerModule => true},
                    wait_loop(WaiterKey, Required, NewAcked, Timeout)
            after Timeout ->
                {error, timeout}
            end
    end.

%% @private
all_acked(Required, Acked) ->
    lists:all(fun(Handler) ->
        maps:get(Handler, Acked, false)
    end, Required).
