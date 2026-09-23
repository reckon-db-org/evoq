%% @doc Combined evoq_event_store + evoq_subscriptions adapter for testing
%% evoq_store_subscription's boot and restart behavior without a live
%% reckon-db store.
%%
%% Faithfully models the exact mechanism `reckon_db_subscriptions' actually
%% implements (read the real source, not guessed): a BRAND NEW subscription
%% honors the `start_from' its caller passes; a RECONNECT (a subscription
%% under the same name that already exists) ignores the caller's
%% `start_from' and resumes from whatever checkpoint was last `ack'ed. This
%% is the seam evoq_store_subscription's own double-delivery fix depends
%% on, so the fake must get it exactly right or the tests prove nothing.
-module(evoq_fake_boot_backend).

-export([seed/2, push_live/2, reset/1, delivered_count/1, persisted_checkpoint/2]).
-export([read_all_global/3]).
-export([subscribe/5, unsubscribe/2, ack/4, get_checkpoint/2, list/1, get_by_name/2]).

seed(StoreId, Events) ->
    ensure_table(),
    ets:insert(?MODULE, {{events, StoreId}, Events}),
    ok.

%% @doc Appends NewEvents to the store (a future catch-up sees them, same
%% as a real append would) AND, if a live subscriber is currently
%% connected, pushes them directly via `{events, NewEvents}' -- modeling
%% a real Khepri trigger firing in real time, which is a DIFFERENT path
%% from the catch-up loop's own polling (deliver_from/3). Real live
%% events are NOT counted in delivered_count/1 -- that metric is
%% specifically about redundant catch-up-triggered redelivery; a single,
%% real, expected live push is not the thing this fake exists to catch.
push_live(StoreId, NewEvents) ->
    ensure_table(),
    Existing = case ets:lookup(?MODULE, {events, StoreId}) of
        [{_, Es}] -> Es;
        [] -> []
    end,
    ets:insert(?MODULE, {{events, StoreId}, Existing ++ NewEvents}),
    case ets:lookup(?MODULE, {live_pid, StoreId}) of
        [{_, Pid}] when is_pid(Pid) -> Pid ! {events, NewEvents};
        _ -> ok
    end,
    ok.

reset(StoreId) ->
    ensure_table(),
    ets:match_delete(?MODULE, {{sub, StoreId, '_'}, '_'}),
    ets:delete(?MODULE, {live_pid, StoreId}),
    ets:insert(?MODULE, {{delivered, StoreId}, 0}),
    ok.

%% @doc Cumulative count of events actually pushed to a subscriber via
%% deliver_from/3, across every subscribe/reconnect this test session has
%% done for StoreId. The metric the double-delivery bug is about: if this
%% ends up higher than the number of events seeded, something got
%% delivered more than once.
delivered_count(StoreId) ->
    case ets:lookup(?MODULE, {delivered, StoreId}) of
        [{_, N}] -> N;
        [] -> 0
    end.

bump_delivered(StoreId, N) ->
    ets:update_counter(?MODULE, {delivered, StoreId}, N, {{delivered, StoreId}, 0}).

%% @doc Test introspection: whatever checkpoint is currently persisted
%% for {StoreId, SubName}, or `undefined' if no subscription exists.
persisted_checkpoint(StoreId, SubName) ->
    case ets:lookup(?MODULE, {sub, StoreId, SubName}) of
        [{_, CP}] -> CP;
        [] -> undefined
    end.

ensure_table() ->
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, set]);
        _ -> ok
    end.

%% --- evoq_event_store adapter surface ---

read_all_global(StoreId, Offset, BatchSize) ->
    Events = case ets:lookup(?MODULE, {events, StoreId}) of
        [{_, Es}] -> Es;
        [] -> []
    end,
    Len = length(Events),
    case Offset >= Len of
        true -> {ok, []};
        false ->
            Last = min(Offset + BatchSize, Len),
            {ok, lists:sublist(Events, Offset + 1, Last - Offset)}
    end.

%% --- evoq_subscriptions adapter surface ---

subscribe(StoreId, _Type, _Selector, SubName, Opts) ->
    ensure_table(),
    Key = {sub, StoreId, SubName},
    StartFrom = maps:get(start_from, Opts, 0),
    SubscriberPid = maps:get(subscriber_pid, Opts, undefined),
    Checkpoint = case ets:lookup(?MODULE, Key) of
        [{_, CP}] -> CP;
        [] -> StartFrom
    end,
    ets:insert(?MODULE, {Key, Checkpoint}),
    ets:insert(?MODULE, {{live_pid, StoreId}, SubscriberPid}),
    spawn(fun() -> deliver_from(StoreId, Checkpoint, SubscriberPid) end),
    {ok, <<"fake-sub">>}.

deliver_from(StoreId, Offset, Pid) ->
    case read_all_global(StoreId, Offset, 500) of
        {ok, []} -> ok;
        {ok, Events} ->
            bump_delivered(StoreId, length(Events)),
            Pid ! {events, Events},
            deliver_from(StoreId, Offset + length(Events), Pid)
    end.

%% Mirrors reckon_db_subscriptions:ack/4 -> do_ack_checkpoint/4 ->
%% reckon_db_subscriptions_store:update_checkpoint/3 exactly: acking a
%% subscription that doesn't exist yet is a no-op error, NOT a silent
%% create. Getting this wrong would let a test pass because the fake
%% "created" a checkpoint entry that the real store would have rejected,
%% masking a genuinely broken start_from.
ack(StoreId, SubName, _StreamId, Position) ->
    ensure_table(),
    Key = {sub, StoreId, SubName},
    case ets:lookup(?MODULE, Key) of
        [{_, _}] ->
            ets:insert(?MODULE, {Key, Position}),
            ok;
        [] ->
            {error, {subscription_not_found, SubName}}
    end.

%% Mirrors reckon_evoq_adapter:get_checkpoint/2 over
%% reckon_db_subscriptions: the persisted checkpoint of an existing
%% subscription, `{error, not_found}' when none has been created yet.
get_checkpoint(StoreId, SubName) ->
    ensure_table(),
    case ets:lookup(?MODULE, {sub, StoreId, SubName}) of
        [{_, CP}] -> {ok, CP};
        [] -> {error, not_found}
    end.

unsubscribe(_StoreId, _SubId) -> ok.
list(_StoreId) -> {ok, []}.
get_by_name(_StoreId, _Name) -> {error, not_found}.
