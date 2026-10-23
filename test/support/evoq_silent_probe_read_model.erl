%% @doc A read model that does not say whether it survives a restart: no
%% durable/0. It stands for every read model written before evoq asked.
-module(evoq_silent_probe_read_model).
-behaviour(evoq_read_model).
-export([init/1, get/2, put/3, delete/2]).

init(_Config) -> {ok, #{}}.

get(Key, Rows) ->
    case maps:find(Key, Rows) of
        {ok, Value} -> {ok, Value};
        error -> {error, not_found}
    end.

put(Key, Value, Rows) -> {ok, Rows#{Key => Value}}.

delete(Key, Rows) -> {ok, maps:remove(Key, Rows)}.
