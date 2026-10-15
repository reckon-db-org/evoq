%% @doc A store that cannot be read reaches the dispatcher as an error.
%%%
%%% THE LOAD RUNS AFTER INIT NOW (evoq_aggregate:handle_continue/2), which is
%%% what took the replay off the registry's serialised start. Two things follow,
%%% and this test holds both in place:
%%%
%%%   1. the registry hands out a process BEFORE the stream is loaded, because
%%%      loading is no longer its work
%%%   2. a store read that fails therefore happens inside that process, while a
%%%      caller is waiting on it, and execute_command/2 has to answer the caller
%%%      with `{error, _}' rather than let it exit with a process it never owned
%%%
%%% The second is the one a change could quietly break: drop the catch in
%%% execute_command/2 and the caller exits, which the router's own `{error, _}'
%%% clauses never see, and the failure comes back as a crash in a service that
%%% was only reporting one.
-module(evoq_aggregate_load_failure_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

a_store_that_cannot_be_read_is_an_error_test_() ->
    {setup, fun start_deps/0, fun stop_deps/1,
     fun(_Started) -> [fun unreadable_store/0] end}.

unreadable_store() ->
    %% No adapter: evoq_event_store:read/5 raises on the first read, and the
    %% first read is now the aggregate's own load.
    ok = application:unset_env(evoq, event_store_adapter),

    Module = evoq_aggregate_registry_test_agg,
    Store = load_failure_store,
    Id = <<"load-failure-", (integer_to_binary(erlang:unique_integer([positive])))/binary>>,

    %% The registry answers with a process, not with a load failure: the load is
    %% the child's own work now, and that is the shape change this lives beside.
    {ok, Pid} = evoq_aggregate_registry:get_or_start(Module, Id, Store),
    ?assert(is_pid(Pid)),

    %% The caller that was waiting on that process is told what happened.
    Result = evoq_aggregate:execute_command(Pid, command()),
    ?assertMatch({error, _}, Result),
    ?assertNot(is_process_alive(Pid)).

command() ->
    evoq_command:new(test, evoq_aggregate_registry_test_agg, <<"load-failure">>,
                     #{command_type => test}).

%%====================================================================

start_deps() ->
    evoq_test_isolation:stop_leftover_evoq(),
    {ok, Started} = application:ensure_all_started(evoq),
    Started.

stop_deps(Started) ->
    lists:foreach(fun application:stop/1, lists:reverse(Started)).
