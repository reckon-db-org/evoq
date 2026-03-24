%% @doc Unit tests for evoq_aggregate_registry.
%%
%% Tests concurrent get_or_start race condition handling.
-module(evoq_aggregate_registry_tests).

-include_lib("eunit/include/eunit.hrl").

%%====================================================================
%% Test: start_aggregate handles already_started
%%====================================================================

%% The registry's start_aggregate wraps supervisor:start_child.
%% When two concurrent callers race, the second gets
%% {error, {already_started, Pid}}. The registry must return {ok, Pid}.
already_started_returns_ok_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1, [
        fun concurrent_get_or_start_same_aggregate/0
    ]}.

start_deps() ->
    application:ensure_all_started(evoq),
    ok.

stop_deps(_) ->
    ok.

concurrent_get_or_start_same_aggregate() ->
    AggId = <<"race-test-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Module = evoq_aggregate_registry_test_agg,
    StoreId = race_test_store,

    Self = self(),
    Ref = make_ref(),
    N = 10,

    %% Spawn N concurrent callers for the same aggregate
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Result = evoq_aggregate_registry:get_or_start(Module, AggId, StoreId),
            Self ! {Ref, Result}
        end)
    end, lists:seq(1, N)),

    %% Collect results
    Results = collect(Ref, N, []),

    %% Some may fail because the aggregate init can't reach the store.
    %% But any that succeed must return the same Pid, and NONE should
    %% return {error, {already_started, _}} — that must be handled internally.
    NoAlreadyStarted = [R || {error, {already_started, _}} = R <- Results],
    ?assertEqual([], NoAlreadyStarted),

    %% All successful results should have the same Pid
    OkPids = [Pid || {ok, Pid} <- Results],
    case OkPids of
        [] ->
            %% All failed (no store) — that's fine, the point is no already_started leak
            ok;
        _ ->
            UniquePids = lists:usort(OkPids),
            ?assertEqual(1, length(UniquePids))
    end.

%%====================================================================
%% Helpers
%%====================================================================

collect(_Ref, 0, Acc) -> Acc;
collect(Ref, Remaining, Acc) ->
    receive
        {Ref, Result} -> collect(Ref, Remaining - 1, [Result | Acc])
    after 5000 ->
        Acc
    end.
