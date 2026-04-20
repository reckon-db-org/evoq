#!/usr/bin/env escript
%%! -noshell -config config/sys.config

main([SliceStr, ScenarioFile, OutPath, Profile]) ->
    io:format("[run_slice] starting~n"),
    lists:foreach(fun code:add_pathz/1,
                  filelib:wildcard("_build/bench/checkouts/*/ebin")),
    lists:foreach(fun code:add_pathz/1,
                  filelib:wildcard("_build/default/lib/*/ebin")),
    code:add_pathz("_build/bench/extras/slices"),

    {ok, _} = application:ensure_all_started(reckon_db),
    {ok, _} = application:ensure_all_started(reckon_gater),
    {ok, _} = application:ensure_all_started(evoq),
    {ok, _} = application:ensure_all_started(reckon_evoq),
    {ok, _} = application:ensure_all_started(reckon_bench_harness),
    io:format("[run_slice] apps started~n"),

    ok = wait_for_store(bench_store, 30),
    io:format("[run_slice] store ready~n"),

    %% Point evoq at the bench_store for default dispatch opts.
    application:set_env(evoq, store_id, bench_store),
    io:format("[run_slice] evoq store_id set~n"),

    SliceMod = list_to_atom(SliceStr),
    try
        reckon_bench_harness:run_slice(
          SliceMod,
          ScenarioFile,
          OutPath,
          list_to_binary(Profile))
    catch
        C:Err:St ->
            io:format("bench crashed: ~p:~p~n~p~n", [C, Err, St]),
            halt(2)
    end,
    halt(0);
main(_) ->
    io:format("usage: run_slice.escript <slice> <scenario-file> <out> <profile>~n"),
    halt(2).

wait_for_store(StoreId, 0) ->
    error({store_never_ready, StoreId});
wait_for_store(StoreId, Retries) ->
    Stores = reckon_db_sup:which_stores(),
    case lists:member(StoreId, Stores) of
        true  -> timer:sleep(1000), ok;
        false -> timer:sleep(500),  wait_for_store(StoreId, Retries - 1)
    end.
