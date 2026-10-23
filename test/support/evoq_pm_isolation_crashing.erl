%% @doc A process manager written as the guide's basic one is (evoq#9):
%% correlate/2 has no catch-all, so an event without an `id' raises
%% function_clause, and handle/3 raises on the type that says so.
-module(evoq_pm_isolation_crashing).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2]).

interested_in() -> [<<"isolation_probed_v1">>, <<"isolation_handler_broke_v1">>].

correlate(#{data := #{id := Id}}, _Metadata) -> {continue, Id}.

handle(_State, #{event_type := <<"isolation_handler_broke_v1">>}, _Metadata) ->
    error(handler_broke);
handle(State, _Event, _Metadata) ->
    {ok, State}.

apply(State, _Event) -> State.
