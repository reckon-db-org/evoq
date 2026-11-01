%%% @doc A replay never reaches `before_dispatch', so a kill switch does not
%%% stop it (evoq#46).
%%%
%%% `evoq_command_router:dispatch/2' checks the idempotency cache before it
%%% builds the pipeline, and `evoq_idempotency:check_and_store/3' returns a
%%% cached result without calling the fun it was given. A command replayed with
%%% a known `idempotency_key' therefore never runs `before_dispatch': an
%%% authorization that has since been revoked, a maintenance window, a kill
%%% switch -- none of them are asked, and the caller is handed the stored
%%% success it is no longer entitled to.
%%%
%%% The command does not execute, so this is not #41's class (a check bypassed
%%% while the command runs). What is bypassed is every decision the chain makes
%%% about the CALLER.
-module(evoq_router_replay_gate_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(DENY_ALL, evoq_middleware_deny_all).
-define(STREAM_VERSION, 7).

replay_gate_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun a_first_dispatch_is_refused_by_the_gate/0,
        fun a_replay_is_refused_by_the_gate/0,
        fun a_cross_path_replay_is_refused_by_the_gate/0,
        fun a_refusal_does_not_write_a_cache_entry/0,
        fun a_refusal_does_not_change_an_existing_cache_entry/0
    ]}.

start() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    meck:new(evoq_event_store, [passthrough, no_link]),
    meck:expect(evoq_event_store, read, 5,
                fun(_Store, _Stream, _From, _Count, _Dir) -> {ok, []} end),
    meck:expect(evoq_event_store, append, 4,
                fun(_Store, _Stream, _Expected, _Events) -> {ok, ?STREAM_VERSION} end),
    Started.

stop(Started) ->
    meck:unload(evoq_event_store),
    lists:foreach(fun application:stop/1, lists:reverse(Started)).

%%====================================================================
%% The gate holds on the first dispatch, as it always did
%%====================================================================

a_first_dispatch_is_refused_by_the_gate() ->
    ?assertEqual({error, denied}, dispatch(<<"first-dispatch">>, [?DENY_ALL])).

%%====================================================================
%% The defect: the same command, replayed, never reaches the gate
%%====================================================================

a_replay_is_refused_by_the_gate() ->
    Key = <<"replay-gate">>,
    ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(Key, [])),
    %% Same command, same idempotency key: the store answers from its cache.
    %% The kill switch must still be asked.
    ?assertEqual({error, denied}, dispatch(Key, [?DENY_ALL])).

%% A `dispatch_with_state/2' replay cannot hit a cache entry of its own: nothing
%% about that path is cached at all (evoq#49), so a with_state -> with_state
%% replay re-executes under either router and this would pin nothing. The bypass
%% on that path is CROSS-PATH, and it is the one a caller reaches by retrying a
%% `dispatch/2' through `dispatch_with_state/2': the 3-tuple `dispatch/2' cached
%% answers the with_state call before the gate is asked.
a_cross_path_replay_is_refused_by_the_gate() ->
    Key = <<"replay-gate-cross">>,
    ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(Key, [])),
    ?assertEqual({error, denied}, dispatch_with_state(Key, [?DENY_ALL])).

%%====================================================================
%% A refusal reads and writes nothing: it cannot poison the cache either
%%====================================================================

a_refusal_does_not_write_a_cache_entry() ->
    Key = <<"replay-gate-refusal">>,
    ?assertEqual({error, denied}, dispatch(Key, [?DENY_ALL])),
    ?assertEqual(not_found, evoq_idempotency:lookup(cache_key(Key))),
    %% The control: the same lookup DOES find an entry once a dispatch
    %% succeeds, so the assertion above is not passing on a key the router
    %% never writes under (evoq#51 scoped it).
    ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(Key, [])),
    ?assertMatch({ok, _}, evoq_idempotency:lookup(cache_key(Key))).

a_refusal_does_not_change_an_existing_cache_entry() ->
    Key = <<"replay-gate-unchanged">>,
    ?assertMatch({ok, ?STREAM_VERSION, [_]}, dispatch(Key, [])),
    ?assertMatch({ok, _}, evoq_idempotency:lookup(cache_key(Key))),
    Stored = evoq_idempotency:lookup(cache_key(Key)),
    ?assertEqual({error, denied}, dispatch(Key, [?DENY_ALL])),
    ?assertEqual(Stored, evoq_idempotency:lookup(cache_key(Key))).

%%====================================================================
%% Helpers
%%====================================================================

%% The key the router caches under (evoq#51): the whole dispatch, not the
%% bare idempotency key. Written out here rather than exported from the
%% router, so a change to its shape fails these tests instead of quietly
%% turning them into assertions about an entry nothing writes.
cache_key(Key) ->
    {test_store, evoq_strong_probe_aggregate, <<"replay-gate-stream">>, replay_probe, Key}.

%%====================================================================
%% Helpers
%%====================================================================

dispatch(Key, Middleware) ->
    evoq_command_router:dispatch(command(Key), opts(Middleware)).

dispatch_with_state(Key, Middleware) ->
    evoq_command_router:dispatch_with_state(command(Key), opts(Middleware)).

opts(Middleware) ->
    #{store_id => test_store, middleware => Middleware}.

%% The SAME command every time: same command_id and same idempotency_key, which
%% is what a retry after an ambiguous answer looks like.
command(Key) ->
    (evoq_command:new(replay_probe, evoq_strong_probe_aggregate,
                      <<"replay-gate-stream">>, #{command_type => <<"emit_strong_probe">>}))
        #evoq_command{command_id = Key, idempotency_key = Key}.
