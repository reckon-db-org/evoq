%%% @doc A halt without a response is never reported as `undefined' (evoq#41).
%%%
%%% `evoq_command_router:dispatch/2' builds the pipeline with
%%% `response = undefined'. A `before_dispatch' middleware that calls
%%% `evoq_middleware:halt/1' without `respond/2' correctly stops the command, but
%%% the router then returns that same `undefined' to the caller. A caller written
%%% the ordinary way --
%%%
%%%     case dispatch(Cmd, Opts) of {error, R} -> deny(R); _ -> accept end
%%%
%%% -- accepts a command that was never executed. The refusal is indistinguishable
%%% from "not an error", which is the fail-open shape #39's refusals exist to
%%% prevent, one layer further out: the router refuses and then says nothing.
%%%
%%% What must hold afterwards: a halt with no response is an error a caller can
%%% see, and a halt that DID respond is still returned exactly as the middleware
%%% gave it.
-module(evoq_router_halt_without_response_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(HALT_ONLY, evoq_middleware_halt_only).
-define(DENY_ALL, evoq_middleware_deny_all).
-define(HALT_SUCCESS, evoq_middleware_halt_success).

halt_without_response_test_() ->
    {setup, fun start/0, fun stop/1, [
        fun a_halt_without_a_response_is_an_error/0,
        fun a_halt_without_a_response_is_an_error_with_state/0,
        fun a_halt_that_responded_keeps_its_response/0,
        fun a_halt_that_responded_keeps_its_response_with_state/0,
        fun a_success_from_a_halt_is_answered_as_given_with_state/0
    ]}.

%% The idempotency store is application-wide and another test module may already
%% have started it: reuse a running one rather than failing on `already_started',
%% and only stop what this fixture started.
start() ->
    application:ensure_all_started(telemetry),
    case evoq_idempotency:start_link() of
        {ok, Pid} -> {started, Pid};
        {error, {already_started, Pid}} -> {running, Pid}
    end.

stop({started, Pid}) ->
    gen_server:stop(Pid);
stop({running, _Pid}) ->
    ok.

%%====================================================================
%% The defect
%%====================================================================

a_halt_without_a_response_is_an_error() ->
    Result = evoq_command_router:dispatch(command(), #{middleware => [?HALT_ONLY]}),
    ?assertNotEqual(undefined, Result),
    ?assertEqual({error, halted_without_response}, Result).

a_halt_without_a_response_is_an_error_with_state() ->
    Result = evoq_command_router:dispatch_with_state(command(),
                                                    #{middleware => [?HALT_ONLY]}),
    ?assertNotEqual(undefined, Result),
    ?assertEqual({error, halted_without_response}, Result).

%%====================================================================
%% The half that must not change
%%====================================================================

a_halt_that_responded_keeps_its_response() ->
    Result = evoq_command_router:dispatch(command(), #{middleware => [?DENY_ALL]}),
    ?assertEqual({error, denied}, Result).

a_halt_that_responded_keeps_its_response_with_state() ->
    Result = evoq_command_router:dispatch_with_state(command(), #{middleware => [?DENY_ALL]}),
    ?assertEqual({error, denied}, Result).

%% A halt that answers SUCCESS is answered as the middleware gave it, even from
%% a function whose ordinary answer carries the aggregate state (evoq#47). No
%% aggregate ran, so there is no state to carry; inventing an `undefined' one
%% would hand the caller a value it could mistake for the aggregate's.
a_success_from_a_halt_is_answered_as_given_with_state() ->
    Result = evoq_command_router:dispatch_with_state(command(),
                                                    #{middleware => [?HALT_SUCCESS]}),
    ?assertEqual({ok, 0, []}, Result).

%%====================================================================

%% A fresh command per dispatch: dispatch/2 caches a successful result by
%% command_id, and this test is about what a refusal looks like, not about
%% whether one is cached.
command() ->
    evoq_command:new(halt_probe, halt_probe_aggregate, <<"halt-probe-stream">>, #{}).
