%% @doc Dead letter store for failed events.
%%
%% Stores events that could not be processed after all retries.
%% Provides API to:
%% - Store failed events
%% - List dead letter entries
%% - Retry dead letter entries
%% - Delete entries after successful reprocessing
%%
%% Uses ETS for fast in-memory storage. For production, consider
%% implementing a persistent store.
%%
%% @author rgfaber
-module(evoq_dead_letter).
-behaviour(gen_server).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% API
-export([start_link/0]).
-export([store/3, store/4]).
-export([list/0, list/1]).
-export([get/1]).
-export([delete/1]).
-export([retry/1]).
-export([count/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(TABLE, evoq_dead_letter_table).

-record(state, {}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the dead letter store.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, [], []).

%% @doc Store a failed event in the dead letter queue.
-spec store(map(), atom(), #evoq_failure_context{}) -> ok.
store(Event, HandlerModule, FailureContext) ->
    store(Event, HandlerModule, FailureContext, undefined).

%% @doc Store a failed event with optional error reason.
-spec store(map(), atom(), #evoq_failure_context{}, term()) -> ok.
store(Event, HandlerModule, FailureContext, Reason) ->
    gen_server:call(?SERVER, {store, Event, HandlerModule, FailureContext, Reason}).

%% @doc List all dead letter entries.
-spec list() -> [#evoq_dead_letter{}].
list() ->
    list(#{}).

%% @doc List dead letter entries with filters.
%% Filters:
%% - handler: Filter by handler module
%% - since: Filter by created_at (milliseconds since epoch)
%% - limit: Max number of entries to return
-spec list(map()) -> [#evoq_dead_letter{}].
list(Filters) ->
    gen_server:call(?SERVER, {list, Filters}).

%% @doc Get a specific dead letter entry by ID.
-spec get(binary()) -> {ok, #evoq_dead_letter{}} | {error, not_found}.
get(Id) ->
    gen_server:call(?SERVER, {get, Id}).

%% @doc Delete a dead letter entry.
-spec delete(binary()) -> ok | {error, not_found}.
delete(Id) ->
    gen_server:call(?SERVER, {delete, Id}).

%% @doc Retry a dead letter entry.
%% Returns the event and handler for reprocessing.
-spec retry(binary()) -> {ok, map(), atom()} | {error, not_found}.
retry(Id) ->
    gen_server:call(?SERVER, {retry, Id}).

%% @doc Get count of dead letter entries.
-spec count() -> non_neg_integer().
count() ->
    gen_server:call(?SERVER, count).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init([]) ->
    %% Create ETS table
    _ = create_table(),
    {ok, #state{}}.

%% @private
handle_call({store, Event, HandlerModule, FailureContext, Reason}, _From, State) ->
    Id = generate_id(),
    Entry = #evoq_dead_letter{
        id = Id,
        event = Event,
        handler_module = HandlerModule,
        error = FailureContext#evoq_failure_context.error,
        failure_context = FailureContext,
        created_at = erlang:system_time(millisecond)
    },
    ets:insert(?TABLE, {Id, Entry}),

    %% Emit telemetry
    telemetry:execute(?TELEMETRY_HANDLER_DEAD_LETTER, #{
        count => ets:info(?TABLE, size)
    }, #{
        handler => HandlerModule,
        id => Id,
        reason => Reason
    }),

    {reply, ok, State};

handle_call({list, Filters}, _From, State) ->
    AllEntries = [Entry || {_Id, Entry} <- ets:tab2list(?TABLE)],
    FilteredEntries = apply_filters(AllEntries, Filters),
    {reply, FilteredEntries, State};

handle_call({get, Id}, _From, State) ->
    Result = case ets:lookup(?TABLE, Id) of
        [{Id, Entry}] -> {ok, Entry};
        [] -> {error, not_found}
    end,
    {reply, Result, State};

handle_call({delete, Id}, _From, State) ->
    Result = case ets:lookup(?TABLE, Id) of
        [{Id, _Entry}] ->
            ets:delete(?TABLE, Id),
            ok;
        [] ->
            {error, not_found}
    end,
    {reply, Result, State};

handle_call({retry, Id}, _From, State) ->
    Result = case ets:lookup(?TABLE, Id) of
        [{Id, #evoq_dead_letter{event = Event, handler_module = Handler}}] ->
            %% Don't delete yet - let caller decide after successful retry
            {ok, Event, Handler};
        [] ->
            {error, not_found}
    end,
    {reply, Result, State};

handle_call(count, _From, State) ->
    Count = ets:info(?TABLE, size),
    {reply, Count, State};

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

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
create_table() ->
    case ets:whereis(?TABLE) of
        undefined ->
            ets:new(?TABLE, [
                named_table,
                public,
                set,
                {read_concurrency, true}
            ]);
        _Tid ->
            ?TABLE
    end.

%% @private
generate_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    binary:encode_hex(Bytes).

%% @private
apply_filters(Entries, Filters) ->
    Entries1 = filter_by_handler(Entries, maps:get(handler, Filters, undefined)),
    Entries2 = filter_by_since(Entries1, maps:get(since, Filters, undefined)),
    Entries3 = apply_limit(Entries2, maps:get(limit, Filters, undefined)),
    Entries3.

%% @private
filter_by_handler(Entries, undefined) -> Entries;
filter_by_handler(Entries, Handler) ->
    [E || #evoq_dead_letter{handler_module = H} = E <- Entries, H =:= Handler].

%% @private
filter_by_since(Entries, undefined) -> Entries;
filter_by_since(Entries, Since) ->
    [E || #evoq_dead_letter{created_at = T} = E <- Entries, T >= Since].

%% @private
apply_limit(Entries, undefined) -> Entries;
apply_limit(Entries, Limit) -> lists:sublist(Entries, Limit).
