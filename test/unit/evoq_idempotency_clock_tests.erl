%% @doc An idempotency entry lives for its TTL of elapsed time, whatever the
%% wall clock does (evoq#13).
%%
%% The deadline was erlang:system_time(millisecond) + TTL, compared with a
%% wall-clock Now: a forward NTP step of at least the TTL expired every
%% cached result at once, and a duplicate command re-executed, which is what
%% the store exists to prevent. A backward step kept entries past their TTL.
%% The table is node-local and never persisted, so its deadlines are read
%% from the monotonic clock.
-module(evoq_idempotency_clock_tests).

-include_lib("eunit/include/eunit.hrl").

-define(TTL, 60000).

idempotency_test_() ->
    {setup, fun start/0, fun stop/1,
     [fun the_deadline_is_on_the_monotonic_clock/0,
      fun an_entry_is_found_within_its_ttl/0,
      fun an_entry_is_gone_after_its_ttl/0]}.

%% The wall clock cannot be stepped from a test; the deadline's clock can be
%% read. One read from the wall clock is tens of years away from the
%% monotonic window around the store.
the_deadline_is_on_the_monotonic_clock() ->
    Before = erlang:monotonic_time(millisecond),
    ok = evoq_idempotency:store(<<"cmd-deadline">>, {ok, 1}, ?TTL),
    After = erlang:monotonic_time(millisecond),
    [{_, _, ExpiresAt}] = ets:lookup(evoq_idempotency_table, <<"cmd-deadline">>),
    ?assert(ExpiresAt >= Before + ?TTL),
    ?assert(ExpiresAt =< After + ?TTL).

an_entry_is_found_within_its_ttl() ->
    ok = evoq_idempotency:store(<<"cmd-live">>, {ok, 2}, ?TTL),
    ?assertEqual({ok, {ok, 2}}, evoq_idempotency:lookup(<<"cmd-live">>)).

an_entry_is_gone_after_its_ttl() ->
    ok = evoq_idempotency:store(<<"cmd-short">>, {ok, 3}, 20),
    timer:sleep(40),
    ?assertEqual(not_found, evoq_idempotency:lookup(<<"cmd-short">>)).

%% Guard: no module takes a deadline from the wall clock. The duration guard
%% in evoq_telemetry_units_tests catches a subtraction; a deadline is an
%% addition, which it let through.
no_deadline_is_taken_from_the_wall_clock_test() ->
    Dir = filename:join(code:lib_dir(evoq), "src"),
    {ok, Files} = file:list_dir(Dir),
    ?assert(lists:member("evoq_idempotency.erl", Files)),
    Offenders = [F || F <- Files, filename:extension(F) =:= ".erl",
                      {ok, Bin} <- [file:read_file(filename:join(Dir, F))],
                      adds_to_wall_clock(code_only(Bin))],
    ?assertEqual([], Offenders).

adds_to_wall_clock(Code) ->
    re:run(Code, "system_time\\([a-z_]*\\)\\s*\\+", []) =/= nomatch.

code_only(Bin) ->
    Lines = binary:split(Bin, <<"\n">>, [global]),
    iolist_to_binary([[re:replace(L, "%.*$", "", [{return, binary}]), $\n] || L <- Lines]).

start() ->
    {ok, _} = application:ensure_all_started(telemetry),
    {ok, Pid} = evoq_idempotency:start_link(),
    Pid.

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid).
