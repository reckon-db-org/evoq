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

restart_resumes_from_acked_checkpoint_not_from_zero_test() ->
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
    %% reckon_db_subscriptions: the persisted subscription survives with
    %% whatever checkpoint was last acked (20, from Boot 1's own
    %% start_from -- see subscribe_to_all/3's comment), and its old
    %% subscriber pid is simply dead.
    unlink(Boot1),
    MRef = erlang:monitor(process, Boot1),
    exit(Boot1, kill),
    receive {'DOWN', MRef, process, Boot1, _} -> ok after 2000 -> error(boot1_did_not_die) end,

    %% The store grows by 10 while "the service is down" -- these are the
    %% only events a correct restart should ever redeliver.
    evoq_fake_boot_backend:seed(StoreId, events(1, 30)),

    %% Boot 2: a genuinely different pid, same StoreId/subscription name.
    {ok, Boot2} = evoq_store_subscription:start_link(StoreId),
    settle(),

    %% Must be exactly the 10 new events -- not 0 (that would mean they
    %% were silently lost) and not 30 (that would mean the old bug: a
    %% restart redelivering the entire store because the checkpoint never
    %% advanced past 0).
    ?assertEqual(10, evoq_fake_boot_backend:delivered_count(StoreId)),

    stop_subscription(Boot2).

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
