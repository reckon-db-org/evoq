%% @doc Shared recorder for the replay tests: what each probe was handed,
%% and with which metadata, in delivery order. Owned by a process of its
%% own so the table outlives whichever test process happens to create it.
-module(evoq_replay_probe).

-export([reset/0, record/3, calls/1]).

reset() ->
    case ets:whereis(?MODULE) of
        undefined ->
            Self = self(),
            spawn(fun() ->
                ets:new(?MODULE, [named_table, public, bag]),
                Self ! table_ready,
                receive stop -> ok end
            end),
            receive table_ready -> ok after 2000 -> error(probe_table_not_ready) end;
        _ ->
            ets:delete_all_objects(?MODULE)
    end,
    ok.

%% Who is a probe name (skip_handler, open_handler, pm_handle, pm_apply).
record(Who, N, Metadata) ->
    ets:insert(?MODULE, {Who, erlang:unique_integer([monotonic]), N, Metadata}),
    ok.

%% [{N, Metadata}] for one probe, in the order it was handed them.
calls(Who) ->
    [{N, M} || {_, _, N, M} <- lists:keysort(2, ets:lookup(?MODULE, Who))].
