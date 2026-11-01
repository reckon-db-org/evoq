%%% @doc An idempotency entry belongs to a dispatch, not to a bare key
%%% (evoq#51).
%%%
%%% `evoq_command_router:cache_key/1' used the caller's `idempotency_key'
%%% verbatim, and `evoq_idempotency' keeps one flat ETS set keyed by that
%%% binary alone. Nothing about the dispatch was part of the key: not the
%%% store, not the aggregate type, not the aggregate id. Two commands that
%%% merely shared a key shared an entry, so a caller could be handed the
%%% version and events of somebody else's command, and a client that
%%% generated short or reused keys silently lost its own writes.
%%%
%%% These tests dispatch through the router and count appends at the store.
%%% That is where a collision shows: the second command never reaches its
%%% aggregate because the router answered it from another dispatch's entry,
%%% so the store sees one append where two commands ran.
%%%
%%% ⚠ The shape a `dispatch_with_state/2' call is answered in is NOT pinned
%%% here. It is #49's affair; this module asserts only that a cross-path
%%% retry appends once, which is what the scoped key has to keep true.
-module(evoq_idempotency_scope_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(PROBE, evoq_strong_probe_aggregate).
-define(OTHER, evoq_aggregate_registry_test_agg).
-define(STORE, test_store).

scope_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun a_key_for_one_aggregate_id_does_not_answer_another/0,
        fun a_key_for_one_aggregate_type_does_not_answer_another/0,
        fun a_key_for_one_store_does_not_answer_another/0,
        fun a_key_still_deduplicates_its_own_retry/0,
        fun a_key_deduplicates_across_command_ids/0,
        fun a_cross_path_retry_still_appends_once/0
    ]}.

start() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(_Store, _Stream, _Expected, _Events) -> {ok, 1} end),
    Started.

stop(Started) ->
    meck:unload(evoq_event_store),
    lists:foreach(fun application:stop/1, lists:reverse(Started)).

%%====================================================================
%% The defect: one key answered work that belonged to another dispatch
%%====================================================================

%% Two aggregates of the same type, one key. A client that reuses a key
%% across aggregates must not be answered with the other aggregate's events.
a_key_for_one_aggregate_id_does_not_answer_another() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-aggregate-id">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-a">>), opts(?STORE))),
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-b">>), opts(?STORE))),
    ?assertEqual(2, appends()).

%% Two different aggregate types, one key. The type is read at the cache
%% rather than dispatched, because the aggregate registry hands out a process
%% by aggregate id alone: a second type under the same id never reaches its
%% own aggregate, which is a question of its own and not this package's.
a_key_for_one_aggregate_type_does_not_answer_another() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-aggregate-type">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-c">>), opts(?STORE))),
    ?assertMatch({ok, _}, evoq_idempotency:lookup(scoped(?PROBE, <<"stream-c">>, Key))),
    ?assertEqual(not_found, evoq_idempotency:lookup(scoped(?OTHER, <<"stream-c">>, Key))),
    ?assertEqual(1, appends()).

%% Two stores, one key. The store is the tenancy boundary: an entry made in
%% one must never answer a dispatch that names another.
a_key_for_one_store_does_not_answer_another() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-store">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-d">>), opts(store_one))),
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-d">>), opts(store_two))),
    ?assertEqual(2, appends()).

%%====================================================================
%% What the key still does: it deduplicates the dispatch it was sent for
%%====================================================================

a_key_still_deduplicates_its_own_retry() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-own-retry">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-e">>), opts(?STORE))),
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-e">>), opts(?STORE))),
    ?assertEqual(1, appends()).

%% Scoping must not narrow the promise to one command id: a retry after an
%% ambiguous answer carries a fresh command_id and the same key.
a_key_deduplicates_across_command_ids() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-command-ids">>,
    First = probe(Key, <<"stream-f">>),
    Second = (probe(Key, <<"stream-f">>))#evoq_command{command_id = <<"a-second-id">>},
    ?assertNotEqual(First#evoq_command.command_id, Second#evoq_command.command_id),
    ?assertMatch({ok, _, _}, dispatch(First, opts(?STORE))),
    ?assertMatch({ok, _, _}, dispatch(Second, opts(?STORE))),
    ?assertEqual(1, appends()).

%% A caller that retries a `dispatch/2' through `dispatch_with_state/2' is
%% still retrying ONE command: it must not be appended a second time.
a_cross_path_retry_still_appends_once() ->
    meck:reset(evoq_event_store),
    Key = <<"scope-cross-path">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key, <<"stream-g">>), opts(?STORE))),
    Result = dispatch_with_state(probe(Key, <<"stream-g">>), opts(?STORE)),
    ?assertEqual(ok, element(1, Result)),
    ?assertEqual(1, appends()).

%%====================================================================
%% Helpers
%%====================================================================

appends() ->
    meck:num_calls(evoq_event_store, append, 4).

dispatch(Command, Opts) ->
    evoq_command_router:dispatch(Command, Opts).

dispatch_with_state(Command, Opts) ->
    evoq_command_router:dispatch_with_state(Command, Opts).

opts(StoreId) ->
    #{store_id => StoreId, middleware => []}.

%% The key the router caches under: the whole dispatch, not the bare
%% idempotency key (evoq#51). Written out here rather than exported from the
%% router, so a change to its shape fails these tests instead of quietly
%% turning them into assertions about an entry nothing writes.
scoped(AggregateType, AggregateId, Key) ->
    {?STORE, AggregateType, AggregateId, Key}.

%% The SAME command every time: same command_id and same idempotency_key,
%% which is what a retry after an ambiguous answer looks like.
probe(Key, AggregateId) ->
    (evoq_command:new(probe, ?PROBE, AggregateId,
                      #{command_type => <<"emit_strong_probe">>}))
        #evoq_command{command_id = Key, idempotency_key = Key}.
