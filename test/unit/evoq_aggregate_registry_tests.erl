%% @doc Unit tests for evoq_aggregate_registry.
%%
%% The invariant: concurrent get_or_start for one stream leaves ONE aggregate
%% process. Two would replay the same stream, and the second would append on
%% the state it read before the first append landed, so a legitimate command
%% would come back as a version conflict.
-module(evoq_aggregate_registry_tests).

-include_lib("eunit/include/eunit.hrl").

-define(N, 10).

%%====================================================================
%% Test: one aggregate process per stream, however many callers race
%%====================================================================

one_aggregate_per_stream_under_a_race_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1, [
        fun concurrent_get_or_start_same_aggregate/0
    ]}.

%% The store has to be CONFIGURED here, not absent. With no adapter every
%% start failed, every caller got an error, and the one-pid assertion passed
%% on an empty list for the wrong reason: ten errors looked the same as ten
%% callers agreeing. The adapter answers the replay read with an empty
%% stream, so the aggregate's init really finishes and its process really
%% lives to be counted.
start_deps() ->
    evoq_test_isolation:stop_leftover_evoq(),
    application:set_env(evoq, event_store_adapter, evoq_aggregate_registry_test_store),
    {ok, Started} = application:ensure_all_started(evoq),
    Started.

%% Stop exactly what start_deps/0 started. Leaving evoq's whole supervision
%% tree running made every later module that starts evoq processes of its
%% own fail with already_started.
stop_deps(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)),
    application:unset_env(evoq, event_store_adapter).

concurrent_get_or_start_same_aggregate() ->
    AggId = <<"race-test-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,
    Module = evoq_aggregate_registry_test_agg,
    StoreId = race_test_store,

    Self = self(),
    Ref = make_ref(),

    %% N concurrent callers for the same aggregate.
    lists:foreach(fun(_) ->
        spawn(fun() ->
            Self ! {Ref, evoq_aggregate_registry:get_or_start(Module, AggId, StoreId)}
        end)
    end, lists:seq(1, ?N)),

    Results = collect(Ref, ?N, []),

    %% Every caller answered...
    ?assertEqual(?N, length(Results)),
    ?assertEqual([], [R || {error, _} = R <- Results]),

    %% ...with ONE process, and none of them saw the race.
    UniquePids = lists:usort([Pid || {ok, Pid} <- Results]),
    ?assertEqual(1, length(UniquePids)),
    ?assertEqual([], [R || {error, {already_started, _}} = R <- Results]),
    ?assertEqual({ok, hd(UniquePids)}, evoq_aggregate_registry:lookup(AggId)).

%%====================================================================
%% Helpers
%%====================================================================

collect(_Ref, 0, Acc) -> Acc;
collect(Ref, Remaining, Acc) ->
    receive
        {Ref, Result} -> collect(Ref, Remaining - 1, [Result | Acc])
    after 10000 ->
        Acc
    end.
