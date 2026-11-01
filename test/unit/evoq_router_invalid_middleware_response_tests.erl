%%% @doc A response a middleware supplied is one the caller's spec describes, or
%%% it is refused (evoq#47).
%%%
%%% `evoq_middleware:respond/2' takes any term. A `before_dispatch' that halts
%%% and answers, and an `after_dispatch' or `after_failure' that answers without
%%% halting, both put that term where the caller reads its result:
%%%
%%%     {ok, Version, Events} | {error, Term}            %% dispatch/2
%%%     ... | {ok, Version, Events, State}               %% dispatch_with_state/2
%%%
%%% A middleware answering `ok', `{ok, Version}' or `{rejected, Why}' therefore
%%% reached a caller from a function whose spec said it could not, and a dialyzed
%%% caller written to the spec either crashed on a legitimate answer or was told a
%%% lie by the type.
%%%
%%% The rule is the one #41 set for a halt that says nothing: a response outside
%%% the shapes is refused with a name, never passed through. Same fail-closed
%%% line, one layer out -- the router refuses and then says something the caller
%%% can match.
-module(evoq_router_invalid_middleware_response_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(PROBE, evoq_strong_probe_aggregate).
-define(HALT_ODD, evoq_middleware_halt_odd).
-define(AFTER_ODD, evoq_middleware_after_odd).
-define(STORE, test_store).

invalid_response_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun an_off_spec_halt_response_is_refused/0,
        fun an_off_spec_halt_response_is_refused_with_state/0,
        fun an_off_spec_after_stage_response_is_refused/0,
        fun an_off_spec_after_stage_response_is_refused_with_state/0
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
%% A halt that answers outside the shapes
%%====================================================================

an_off_spec_halt_response_is_refused() ->
    ?assertEqual({error, {invalid_middleware_response, ok}},
                 evoq_command_router:dispatch(command(), opts(?HALT_ODD))).

an_off_spec_halt_response_is_refused_with_state() ->
    ?assertEqual({error, {invalid_middleware_response, ok}},
                 evoq_command_router:dispatch_with_state(command(), opts(?HALT_ODD))).

%%====================================================================
%% An after-stage that answers outside the shapes
%%
%% The command HAS run and the store HAS accepted it by the time this refuses:
%% the caller is told the answer is unusable rather than handed a shape it cannot
%% match. That ordering is the reason #42 puts this class of misconfiguration at
%% boot instead.
%%====================================================================

an_off_spec_after_stage_response_is_refused() ->
    ?assertEqual({error, {invalid_middleware_response, ok}},
                 evoq_command_router:dispatch(command(), opts(?AFTER_ODD))).

an_off_spec_after_stage_response_is_refused_with_state() ->
    ?assertEqual({error, {invalid_middleware_response, ok}},
                 evoq_command_router:dispatch_with_state(command(), opts(?AFTER_ODD))).

%%====================================================================
%% Helpers
%%====================================================================

opts(Middleware) ->
    #{store_id => ?STORE, middleware => [Middleware]}.

command() ->
    evoq_command:new(probe, ?PROBE, <<"invalid-response-stream">>,
                     #{command_type => <<"emit_strong_probe">>}).
