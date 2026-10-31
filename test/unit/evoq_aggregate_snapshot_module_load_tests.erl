%% @doc A snapshot is used even when the aggregate's module has not been loaded.
%%%
%%% `try_load_snapshot/3' asked `erlang:function_exported/3' whether the
%%% aggregate module can be loaded from a snapshot. That function answers FALSE
%%% for a module the VM has not loaded, not only for one that does not export
%%% `from_snapshot/1', so a stream whose module had never been called since the
%%% node started was treated as snapshot-less and replayed from version -1.
%%%
%%% The state that comes out is correct either way, which is why this survived:
%%% a full replay rebuilds the same aggregate. What is lost is the snapshot --
%%% a long stream pays for every event it had already folded into one.
%%%
%%% The check that fails when the fix is reverted: the aggregate module is
%%% DELETED from the VM first, so nothing but `code:ensure_loaded/1' inside the
%%% load can make it visible again. With the fix the replay starts at the
%%% snapshot's version + 1; without it, at 0.
-module(evoq_aggregate_snapshot_module_load_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(AGG, evoq_aggregate_hydration_snapshot_agg).
-define(SNAPSHOT_VERSION, 1499).

a_cold_aggregate_module_still_uses_its_snapshot_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> fun the_snapshot_is_used/0 end}.

%% The snapshot is at 1499 holding `revoked'; the only event after it is never
%% returned, so the state has to have come from the snapshot.
the_snapshot_is_used() ->
    with_the_module_unloaded(fun() ->
        Self = self(),
        with_mocks([{evoq_snapshot_store, load,
                     fun(_Store, _Stream) ->
                         {ok, #{data => #{status => revoked, from => snapshot},
                                version => ?SNAPSHOT_VERSION}}
                     end},
                    {evoq_event_store, read,
                     fun(_Store, _Stream, Start, _Count, forward) ->
                         Self ! {read_start, Start},
                         {ok, []}
                     end}],
                   fun() ->
                       {ok, Pid} = evoq_aggregate_registry:get_or_start(
                                     ?AGG, fresh_id(<<"cold">>), cold_module_store),
                       %% One past the snapshot's version: the snapshot path,
                       %% not the from-zero replay.
                       ?assertEqual(?SNAPSHOT_VERSION + 1, await_read_start()),
                       ?assertEqual({ok, #{status => revoked, from => snapshot}},
                                    evoq_aggregate:get_state(Pid)),
                       ?assertEqual({ok, ?SNAPSHOT_VERSION},
                                    evoq_aggregate:get_version(Pid))
                   end)
    end).

%%====================================================================

%% Deleted from the VM, then proven not loaded: `function_exported/3' would
%% answer false for an exported function of a loaded module too, so the module
%% has to be checked directly or the test would pass for the wrong reason.
%%
%% A module that was never loaded needs no deleting -- `code:delete/1' answers
%% false for it, which is the state this wants anyway.
with_the_module_unloaded(Test) ->
    unload(?AGG),
    ?assertEqual(false, code:is_loaded(?AGG)),
    Test().

unload(Module) ->
    case code:is_loaded(Module) of
        false ->
            ok;
        _ ->
            _ = code:delete(Module),
            _ = code:purge(Module),
            ok
    end.

await_read_start() ->
    receive
        {read_start, Start} -> Start
    after 5000 ->
        error(no_read)
    end.

%% A mock unloaded even when the body raises, so one failing assertion does not
%% leave a module mocked for the next test.
with_mocks(Mocks, Body) ->
    [meck:new(Module, [passthrough]) || {Module, _Function, _Impl} <- Mocks],
    [meck:expect(Module, Function, Impl) || {Module, Function, Impl} <- Mocks],
    try Body() after
        [meck:unload(Module) || {Module, _Function, _Impl} <- Mocks]
    end.

fresh_id(Prefix) ->
    <<Prefix/binary, "-",
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.

start_deps() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    Started.

stop_deps(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)).
