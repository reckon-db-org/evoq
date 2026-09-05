%% @doc Boots real `evoq_store_subscription' gen_servers against
%% `evoq_fake_boot_backend' (a faithful in-memory model of
%% reckon_db_subscriptions' actual checkpoint/reconnect semantics -- see
%% that module's own doc for why the model must be exact) to prove the
%% double-delivery fix end to end: a fresh boot no longer redelivers what
%% catch_up_historical/2 already scanned, and a restart resumes from the
%% acked checkpoint instead of replaying the whole store again.
%%
%% Does not require a live reckon-db/khepri store -- this dev environment's
%% khepri build cannot currently exercise ANY Horus-backed feature
%% (transactions, triggers) under its installed OTP, which blocks testing
%% this against the real store layer directly. The fake backend is built
%% from reading reckon_db_subscriptions' actual source, not guessed: a
%% brand new subscription honors the caller's start_from
%% (store_and_setup/6's Draft), a reconnect ignores it and resumes from
%% the persisted checkpoint instead (reregister_subscriber/4), and ack/4
%% unconditionally overwrites that checkpoint (do_ack_checkpoint/4).
-module(evoq_store_subscription_boot_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

fresh_boot_does_not_redeliver_via_persisted_catchup_test() ->
    ensure_infra(),
    StoreId = unique_store(),
    evoq_fake_boot_backend:seed(StoreId, events(1, 25)),
    evoq_fake_boot_backend:reset(StoreId),

    {ok, Pid} = evoq_store_subscription:start_link(StoreId),
    settle(),

    %% The persisted ($all) subscription's OWN catch-up -- the thing that
    %% used to always start_from=0 -- must have had nothing left to
    %% redeliver: catch_up_historical/2 already scanned all 25 directly.
    ?assertEqual(0, evoq_fake_boot_backend:delivered_count(StoreId)),

    stop_subscription(Pid).

%% Regression test for the exact gap an earlier version of this fix left
%% open (caught by adversarial review, "Experiment A": both boot tests
%% passed even with the pre-subscribe ack_progress/2 call in
%% handle_continue/2 stubbed to a no-op, because subscribe_to_all/3's
%% start_from ALONE already covers a subscription's own first-ever
%% create). This test only distinguishes the two: it forces a RECONNECT
%% (a persisted subscription already exists from Boot 1), which is the
%% one case start_from cannot help with (reregister_subscriber/4 ignores
%% it) and only the pre-subscribe ack closes.
restart_resumes_with_nothing_left_to_redeliver_test() ->
    ensure_infra(),
    StoreId = unique_store(),
    evoq_fake_boot_backend:seed(StoreId, events(1, 20)),
    evoq_fake_boot_backend:reset(StoreId),

    %% Boot 1: a fresh subscription over a 20-event store.
    {ok, Boot1} = evoq_store_subscription:start_link(StoreId),
    settle(),
    ?assertEqual(0, evoq_fake_boot_backend:delivered_count(StoreId)),

    %% Crash it -- unlink first so its exit doesn't take the test process
    %% down too, then kill without ever calling unsubscribe. This is
    %% exactly what a real node restart looks like to
    %% reckon_db_subscriptions: the persisted subscription survives (with
    %% whatever checkpoint was last written) and its old subscriber pid
    %% is simply dead.
    unlink(Boot1),
    MRef = erlang:monitor(process, Boot1),
    exit(Boot1, kill),
    receive {'DOWN', MRef, process, Boot1, _} -> ok after 2000 -> error(boot1_did_not_die) end,

    %% The store grows by 10 while "the service is down".
    evoq_fake_boot_backend:seed(StoreId, events(1, 30)),

    %% Boot 2: a genuinely different pid, same StoreId/subscription name.
    %% Its own Phase 1 rescans all 30 directly (unchanged, pre-existing
    %% behavior -- catch_up_historical/2 always starts at 0, on every
    %% boot, by design; not what this fix touches). What this fix DOES
    %% guarantee: the persisted ($all) subscription's OWN separate
    %% catch-up, reckon_db_subscriptions' `maybe_start_catchup/2', has
    %% NOTHING left to redeliver on top of that -- Boot 2's own
    %% pre-subscribe ack (handle_continue/2) moves the persisted
    %% checkpoint to 30 before its reconnect ever reads the stale value
    %% Boot 1 left behind, so reregister_subscriber/4's do_catchup finds
    %% the store already fully covered.
    {ok, Boot2} = evoq_store_subscription:start_link(StoreId),
    settle(),

    ?assertEqual(0, evoq_fake_boot_backend:delivered_count(StoreId)),

    stop_subscription(Boot2).

%% Isolates the SAME property this fix relies on but from the checkpoint
%% mechanism's own side, independent of evoq_store_subscription: acking a
%% subscription that already exists moves its checkpoint immediately (the
%% property Boot 2's pre-subscribe ack above depends on), while acking one
%% that does not exist yet is a harmless no-op (the property that makes
%% the SAME call safe to make unconditionally on a genuinely fresh boot,
%% where start_from already does the job). Exercises evoq_subscriptions
%% directly, the real evoq API surface (not the fake module's internals).
ack_moves_an_existing_checkpoint_and_no_ops_on_a_missing_one_test() ->
    ensure_infra(),
    StoreId = unique_store(),
    SubName = <<"ack_direct_test">>,
    evoq_fake_boot_backend:reset(StoreId),

    ?assertEqual({error, {subscription_not_found, SubName}},
                 evoq_subscriptions:ack(StoreId, SubName, undefined, 42)),

    {ok, _} = evoq_subscriptions:subscribe(
        StoreId, stream, <<"$all">>, SubName,
        #{subscriber_pid => self(), start_from => 5}),
    ok = evoq_subscriptions:ack(StoreId, SubName, undefined, 99),

    %% A second subscribe under the same name is exactly reconnect's own
    %% shape (an existing entry, ignoring the new start_from) -- prove the
    %% ack above actually stuck by reconnecting with a DIFFERENT
    %% start_from and confirming the fake's own persisted value is 99, not
    %% 5 and not the new call's argument.
    {ok, _} = evoq_subscriptions:subscribe(
        StoreId, stream, <<"$all">>, SubName,
        #{subscriber_pid => self(), start_from => 0}),
    settle(),
    %% Seeded with nothing, so there is nothing at or after offset 99 to
    %% redeliver regardless -- the real assertion is indirect: if ack/4
    %% had been a no-op, reconnect would have resumed from 5 (the
    %% original start_from) instead, which this test cannot distinguish
    %% without seeded data. Cross-checked directly instead: read the
    %% fake's own persisted view.
    ?assertEqual(99, evoq_fake_boot_backend:persisted_checkpoint(StoreId, SubName)).

%%====================================================================
%% Helpers
%%====================================================================

events(From, To) ->
    [#evoq_event{
        event_id = integer_to_binary(N),
        event_type = <<"dd_boot_test_v1">>,
        stream_id = <<"dd-boot-test-stream">>,
        version = N,
        data = #{n => N},
        metadata = #{},
        tags = undefined,
        timestamp = N,
        epoch_us = N
     } || N <- lists:seq(From, To)].

unique_store() ->
    list_to_atom("dd_boot_test_store_" ++
                 integer_to_list(erlang:unique_integer([positive]))).

%% Real reckon_db_subscriptions delivery is asynchronous (a spawned
%% catch-up process); the fake mirrors that on purpose, so give it a beat
%% to finish before asserting.
settle() -> timer:sleep(200).

stop_subscription(Pid) ->
    unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    exit(Pid, shutdown),
    receive {'DOWN', MRef, process, Pid, _} -> ok after 2000 -> ok end.

ensure_infra() ->
    application:set_env(evoq, event_store_adapter, evoq_fake_boot_backend),
    application:set_env(evoq, subscription_adapter, evoq_fake_boot_backend),
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link();
        _ -> ok
    end,
    case whereis(evoq_type_provider) of
        undefined -> {ok, _} = evoq_type_provider:start_link();
        _ -> ok
    end,
    case whereis(evoq_event_router) of
        undefined -> {ok, _} = evoq_event_router:start_link();
        _ -> ok
    end,
    case whereis(evoq_pm_router) of
        undefined -> {ok, _} = evoq_pm_router:start_link();
        _ -> ok
    end,
    ok.
