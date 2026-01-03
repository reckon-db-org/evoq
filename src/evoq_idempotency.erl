%% @doc ETS-based command idempotency store.
%%
%% Stores command results by command_id for deduplication.
%% Duplicate commands return the cached result instead of
%% re-executing against the aggregate.
%%
%% Uses ETS with automatic TTL-based expiration.
%%
%% @author rgfaber
-module(evoq_idempotency).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([start_link/0]).
-export([store/3, lookup/1, delete/1]).
-export([check_and_store/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(TABLE, evoq_idempotency_table).
-define(DEFAULT_TTL, 3600000).  %% 1 hour
-define(CLEANUP_INTERVAL, 60000).  %% 1 minute

-record(state, {
    cleanup_ref :: reference() | undefined
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the idempotency store.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%% @doc Store a command result.
-spec store(binary(), term(), pos_integer()) -> ok.
store(CommandId, Result, TTL) ->
    ExpiresAt = erlang:system_time(millisecond) + TTL,
    ets:insert(?TABLE, {CommandId, Result, ExpiresAt}),
    ok.

%% @doc Lookup a command result.
-spec lookup(binary()) -> {ok, term()} | not_found.
lookup(CommandId) ->
    Now = erlang:system_time(millisecond),
    case ets:lookup(?TABLE, CommandId) of
        [{CommandId, Result, ExpiresAt}] when ExpiresAt > Now ->
            telemetry:execute(?TELEMETRY_IDEMPOTENCY_HIT, #{}, #{
                command_id => CommandId
            }),
            {ok, Result};
        [{CommandId, _Result, _ExpiresAt}] ->
            %% Expired, delete it
            ets:delete(?TABLE, CommandId),
            not_found;
        [] ->
            not_found
    end.

%% @doc Delete a command result.
-spec delete(binary()) -> ok.
delete(CommandId) ->
    ets:delete(?TABLE, CommandId),
    ok.

%% @doc Check for existing result or execute and store.
%% This is the main entry point for idempotent command execution.
-spec check_and_store(binary(), fun(() -> term()), pos_integer()) -> term().
check_and_store(CommandId, ExecuteFun, TTL) ->
    case lookup(CommandId) of
        {ok, CachedResult} ->
            CachedResult;
        not_found ->
            telemetry:execute(?TELEMETRY_IDEMPOTENCY_MISS, #{}, #{
                command_id => CommandId
            }),
            Result = ExecuteFun(),
            %% Only cache successful results
            case Result of
                {ok, _, _} -> store(CommandId, Result, TTL);
                {ok, _} -> store(CommandId, Result, TTL);
                ok -> store(CommandId, Result, TTL);
                _ -> ok
            end,
            Result
    end.

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Create ETS table (delete existing if any from crashed run)
    case ets:whereis(?TABLE) of
        undefined -> ok;
        _Tid -> ets:delete(?TABLE)
    end,

    ?TABLE = ets:new(?TABLE, [
        named_table,
        public,
        set,
        {read_concurrency, true},
        {write_concurrency, true}
    ]),

    %% Start cleanup timer
    Ref = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),

    {ok, #state{cleanup_ref = Ref}}.

%% @private
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(cleanup, State) ->
    cleanup_expired(),
    Ref = erlang:send_after(?CLEANUP_INTERVAL, self(), cleanup),
    {noreply, State#state{cleanup_ref = Ref}};

handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
cleanup_expired() ->
    Now = erlang:system_time(millisecond),
    %% Use match_delete for efficiency
    ets:select_delete(?TABLE, [
        {{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}
    ]).
