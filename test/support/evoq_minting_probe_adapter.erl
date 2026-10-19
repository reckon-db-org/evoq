%% @doc An adapter that mints stream ids, and one that does not: the seam
%% evoq_event_store:new_stream_id/1 delegates to.
%%
%% The id itself is the backend's contract (its format, its time ordering),
%% so evoq asks the adapter rather than minting one itself. This probe
%% answers in a recognisable shape and records what kind of prefix it was
%% asked for, so the test can tell delegation from a guess. It declares no
%% -behaviour(evoq_adapter) on purpose: it implements one callback, and the
%% seam is a function_exported/3 check, not a behaviour conformance one.
-module(evoq_minting_probe_adapter).

-export([new_stream_id/1, asked/0, reset/0]).

new_stream_id(Prefix) ->
    ets_record(Prefix),
    <<(prefix_binary(Prefix))/binary, "-0123456789abcdef0123456789abcdef">>.

prefix_binary(Prefix) when is_atom(Prefix) -> atom_to_binary(Prefix, utf8);
prefix_binary(Prefix) when is_binary(Prefix) -> Prefix.

%% What kind of prefix reached the adapter: atom, binary, none.
asked() ->
    case ets:lookup(?MODULE, asked) of
        [{asked, Kind}] -> Kind;
        [] -> none
    end.

reset() ->
    case ets:whereis(?MODULE) of
        undefined -> _ = ets:new(?MODULE, [named_table, public]), ok;
        _ -> ets:delete_all_objects(?MODULE)
    end.

ets_record(Prefix) when is_atom(Prefix) ->
    ets:insert(?MODULE, {asked, atom});
ets_record(Prefix) when is_binary(Prefix) ->
    ets:insert(?MODULE, {asked, binary}).
