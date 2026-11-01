%%% @doc A `dispatch_with_state/2' result is cached like any other, so its
%%% own retries do not append twice (evoq#49).
%%%
%%% `evoq_idempotency' stored only the shapes its `maybe_cache/3' recognised,
%%% and the state-carrying answer `{ok, Version, Events, State}' matched none
%%% of them: it fell to the catch-all and nothing was stored. A retry of the
%%% same command with the same `idempotency_key' therefore found no entry and
%%% ran the command again, appending the same events a second time -- through
%%% the one path whose whole reason for carrying a key is that a caller may
%%% retry after an ambiguous answer.
%%%
%%% The shape is uniform now: one result is stored per dispatch, whatever entry
%%% point produced it, and each entry point projects it on the way out. So a
%%% caller gets the shape it asked for even when the entry was made by the
%%% other path, and an entry made by either always deduplicates.
-module(evoq_router_with_state_cache_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(PROBE, evoq_strong_probe_aggregate).
-define(STORE, test_store).

with_state_cache_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun a_repeated_dispatch_with_state_appends_once/0,
        fun a_cached_dispatch_with_state_carries_the_state/0,
        fun a_plain_retry_after_a_with_state_dispatch_appends_once/0,
        fun a_with_state_retry_after_a_plain_dispatch_appends_once/0,
        fun a_plain_dispatch_still_answers_a_three_tuple/0
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
%% The defect: the state-carrying answer was never stored
%%====================================================================

a_repeated_dispatch_with_state_appends_once() ->
    meck:reset(evoq_event_store),
    Key = <<"with-state-retry">>,
    First = dispatch_with_state(probe(Key), opts()),
    ?assertMatch({ok, _, _, _}, First),
    Second = dispatch_with_state(probe(Key), opts()),
    ?assertEqual(First, Second),
    ?assertEqual(1, appends()).

%% The stored answer still carries the post-event state: a cache hit is not
%% an answer with the interesting part missing.
a_cached_dispatch_with_state_carries_the_state() ->
    meck:reset(evoq_event_store),
    Key = <<"with-state-carries">>,
    {ok, _Version, _Events, State} = dispatch_with_state(probe(Key), opts()),
    ?assert(is_map(State)),
    ?assertMatch({ok, _, _, State}, dispatch_with_state(probe(Key), opts())),
    ?assertEqual(1, appends()).

%%====================================================================
%% One entry per dispatch, whatever entry point made it
%%====================================================================

%% Retried through `dispatch/2' after a `dispatch_with_state/2' answer: one
%% command, so one append. The plain caller gets the plain shape.
a_plain_retry_after_a_with_state_dispatch_appends_once() ->
    meck:reset(evoq_event_store),
    Key = <<"with-state-then-plain">>,
    ?assertMatch({ok, _, _, _}, dispatch_with_state(probe(Key), opts())),
    ?assertMatch({ok, _, _}, dispatch(probe(Key), opts())),
    ?assertEqual(1, appends()).

%% The same in the other direction: an entry made by `dispatch/2' still
%% answers a `dispatch_with_state/2' call, in the shape that call asked for.
a_with_state_retry_after_a_plain_dispatch_appends_once() ->
    meck:reset(evoq_event_store),
    Key = <<"plain-then-with-state">>,
    ?assertMatch({ok, _, _}, dispatch(probe(Key), opts())),
    ?assertMatch({ok, _, _, _}, dispatch_with_state(probe(Key), opts())),
    ?assertEqual(1, appends()).

%% `dispatch/2' answers in the shape it always did, on a miss and on a hit.
a_plain_dispatch_still_answers_a_three_tuple() ->
    meck:reset(evoq_event_store),
    Key = <<"plain-shape">>,
    ?assertMatch({ok, _, [_]}, dispatch(probe(Key), opts())),
    ?assertMatch({ok, _, [_]}, dispatch(probe(Key), opts())),
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

opts() ->
    #{store_id => ?STORE, middleware => []}.

%% The SAME command every time: same command_id and same idempotency_key,
%% which is what a retry after an ambiguous answer looks like.
probe(Key) ->
    (evoq_command:new(probe, ?PROBE, <<"with-state-stream">>,
                      #{command_type => <<"emit_strong_probe">>}))
        #evoq_command{command_id = Key, idempotency_key = Key}.
