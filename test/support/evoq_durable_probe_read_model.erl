%% @doc A read model that survives a restart, as a database-backed one does:
%% it keeps its rows in persistent_term, which no evoq process owns. Tests
%% pair it with a checkpoint store, which an in-memory read model may not
%% have (see evoq_projection_durable_read_model_tests).
-module(evoq_durable_probe_read_model).
-behaviour(evoq_read_model).
-export([init/1, get/2, put/3, delete/2, list/2, clear/1, durable/0]).

init(Config) ->
    {ok, maps:get(name, Config, ?MODULE)}.

get(Key, Name) ->
    case persistent_term:get({?MODULE, Name, Key}, undefined) of
        undefined -> {error, not_found};
        Value -> {ok, Value}
    end.

put(Key, Value, Name) ->
    persistent_term:put({?MODULE, Name, Key}, Value),
    {ok, Name}.

delete(Key, Name) ->
    _ = persistent_term:erase({?MODULE, Name, Key}),
    {ok, Name}.

list(_Prefix, Name) ->
    {ok, [{K, V} || {{?MODULE, N, K}, V} <- persistent_term:get(), N =:= Name]}.

clear(Name) ->
    [persistent_term:erase(K) || {{?MODULE, N, _} = K, _} <- persistent_term:get(), N =:= Name],
    {ok, Name}.

durable() -> true.
