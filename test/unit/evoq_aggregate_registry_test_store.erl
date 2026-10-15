%% @doc The configured event store for the aggregate registry race test.
%%
%% It exists so the test can assert something about LIVE aggregates. With no
%% adapter configured every start fails inside init, so every caller gets an
%% error and a "one pid" assertion holds over an empty list: true, and about
%% nothing. An empty stream is all the registry test needs, because it starts
%% aggregates and never dispatches a command at one.
-module(evoq_aggregate_registry_test_store).

-export([read/5]).

read(_StoreId, _StreamId, _FromVersion, _Count, _Direction) ->
    {ok, []}.
