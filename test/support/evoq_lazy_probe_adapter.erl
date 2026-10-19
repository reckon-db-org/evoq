%% @doc An adapter that mints, written so a test can reach it by name without
%% loading it.
%%
%% No -behaviour(evoq_adapter) and nothing but new_stream_id/1: the test that
%% uses this module unloads it, sets it as the configured adapter by atom, and
%% calls evoq_event_store:new_stream_id/1. If evoq checks function_exported/3
%% before the module is loaded it reads the adapter as unable to mint, which is
%% the trap this probe exists to catch.
-module(evoq_lazy_probe_adapter).

-export([new_stream_id/1]).

new_stream_id(Prefix) ->
    <<"lazy-", (prefix_binary(Prefix))/binary, "-0123456789abcdef0123456789abcdef">>.

prefix_binary(Prefix) when is_atom(Prefix) -> atom_to_binary(Prefix, utf8);
prefix_binary(Prefix) when is_binary(Prefix) -> Prefix.
