%% @doc An event handler that takes a known time per event, so the duration
%% its telemetry reports can be checked against it.
-module(evoq_slow_probe_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"slow_probe_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, _Event, _Metadata, S) ->
    timer:sleep(50),
    {ok, S}.
