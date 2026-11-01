%% @doc ETS-based command idempotency store.
%%
%% Stores command results by key for deduplication. Duplicate commands
%% return the cached result instead of re-executing against the aggregate.
%%
%% The key is opaque here: the store matches whatever term it is given and
%% knows nothing about what makes two dispatches the same. The command router
%% builds it, and it is the whole dispatch -- store, aggregate type, aggregate
%% id and the caller's key -- not a bare binary (evoq#51).
%%
%% Uses ETS with automatic TTL-based expiration. A TTL is elapsed time:
%% deadlines are read from the monotonic clock, so an NTP step neither
%% expires every entry at once nor keeps one past its TTL (evoq#13). The
%% table is node-local and never persisted, which is what makes that safe.
%%
%% @author rgfaber
-module(evoq_idempotency).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

-type key() :: term().
-export_type([key/0]).

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
-spec store(key(), term(), pos_integer()) -> ok.
store(Key, Result, TTL) ->
    ExpiresAt = erlang:monotonic_time(millisecond) + TTL,
    ets:insert(?TABLE, {Key, Result, ExpiresAt}),
    ok.

%% @doc Lookup a command result.
-spec lookup(key()) -> {ok, term()} | not_found.
lookup(Key) ->
    Now = erlang:monotonic_time(millisecond),
    case ets:lookup(?TABLE, Key) of
        [{Key, Result, ExpiresAt}] when ExpiresAt > Now ->
            telemetry:execute(?TELEMETRY_IDEMPOTENCY_HIT, #{}, #{
                cache_key => Key
            }),
            {ok, Result};
        [{Key, _Result, _ExpiresAt}] ->
            %% Expired, delete it
            ets:delete(?TABLE, Key),
            not_found;
        [] ->
            not_found
    end.

%% @doc Delete a command result.
-spec delete(key()) -> ok.
delete(Key) ->
    ets:delete(?TABLE, Key),
    ok.

%% @doc Check for existing result or execute and store.
%% This is the main entry point for idempotent command execution.
-spec check_and_store(key(), fun(() -> term()), pos_integer()) -> term().
check_and_store(Key, ExecuteFun, TTL) ->
    case lookup(Key) of
        {ok, CachedResult} ->
            CachedResult;
        not_found ->
            telemetry:execute(?TELEMETRY_IDEMPOTENCY_MISS, #{}, #{
                cache_key => Key
            }),
            Result = ExecuteFun(),
            %% Only cache successful results
            maybe_cache(Result, Key, TTL),
            Result
    end.

%% @private Cache only successful results.
maybe_cache({ok, _, _} = Result, Key, TTL) -> store(Key, Result, TTL);
maybe_cache({ok, _} = Result, Key, TTL) -> store(Key, Result, TTL);
maybe_cache(ok = Result, Key, TTL) -> store(Key, Result, TTL);
maybe_cache(_Result, _Key, _TTL) -> ok.

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
    Now = erlang:monotonic_time(millisecond),
    %% Use match_delete for efficiency
    ets:select_delete(?TABLE, [
        {{'_', '_', '$1'}, [{'<', '$1', Now}], [true]}
    ]).
