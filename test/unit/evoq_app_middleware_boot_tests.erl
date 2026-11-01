%%% @doc A configured middleware chain is resolved at boot, not at the first
%%% command (evoq#42).
%%%
%%% Since evoq#39 a name in the chain that cannot be loaded, or that is not a
%%% middleware, refuses the dispatch instead of being skipped. That is the right
%%% answer and the wrong time: the application starts and reports healthy with a
%%% chain that cannot run a single command, the first command is the probe, and
%%% from an `after_*' stage the refusal arrives AFTER the store has accepted the
%%% work.
%%%
%%% These tests start the application with a configured chain and assert that a
%%% bad one fails the start itself. A chain a dispatch carries in its own
%%% `middleware' option cannot be known at boot and keeps the dispatch-time
%%% refusal; evoq_middleware_cold_module_tests covers that path.
-module(evoq_app_middleware_boot_tests).

-include_lib("eunit/include/eunit.hrl").

-define(DENY_ALL, evoq_middleware_deny_all).
-define(HALT_ONLY, evoq_middleware_halt_only).

boot_test_() ->
    {foreach, fun each_start/0, fun each_stop/1, [
        fun a_configured_name_that_cannot_load_refuses_to_start/0,
        fun a_configured_name_that_is_not_a_middleware_refuses_to_start/0,
        fun an_empty_chain_starts/0,
        fun a_good_chain_starts/0
    ]}.

%% Every test starts evoq itself under its own chain, so every test begins with
%% it stopped and its dependencies running.
each_start() ->
    evoq_test_isolation:stop_leftover_evoq(),
    _ = application:load(evoq),
    application:unset_env(evoq, middleware),
    {ok, _} = application:ensure_all_started(evoq),
    _ = application:stop(evoq),
    ok.

each_stop(_) ->
    _ = application:stop(evoq),
    application:unset_env(evoq, middleware),
    ok.

%%====================================================================
%% A chain that cannot run is a boot failure
%%====================================================================

a_configured_name_that_cannot_load_refuses_to_start() ->
    ?assertMatch({error, {{invalid_middleware,
                           {middleware_not_loadable, no_such_middleware_module, _}},
                          {evoq_app, start, _}}},
                 start_with([no_such_middleware_module])).

%% `lists' loads perfectly well and is not a middleware. Configuration that
%% names an API module instead of the middleware beside it is the ordinary way
%% this happens, and it must not look like a chain that passed.
a_configured_name_that_is_not_a_middleware_refuses_to_start() ->
    ?assertMatch({error, {{invalid_middleware, {not_a_middleware, lists}},
                          {evoq_app, start, _}}},
                 start_with([lists])).

%%====================================================================
%% A chain that can run is not affected
%%====================================================================

an_empty_chain_starts() ->
    ?assertEqual(ok, start_with([])).

a_good_chain_starts() ->
    ?assertEqual(ok, start_with([?DENY_ALL, ?HALT_ONLY])).

%%====================================================================
%% Helpers
%%====================================================================

%% The configured chain is put back whatever the start did: a test that left it
%% set would decide what the next one boots with.
start_with(Chain) ->
    ok = application:set_env(evoq, middleware, Chain),
    try application:start(evoq)
    after application:unset_env(evoq, middleware)
    end.
