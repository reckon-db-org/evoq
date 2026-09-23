%% @doc A handler that schedules a message to itself from handle_event/4,
%% the shape of a retry (macula-realm's {republish, ...}), and records
%% what reaches its handle_info/2.
-module(evoq_info_probe_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, handle_info/2]).

interested_in() -> [<<"info_probe_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, #{data := #{n := N}}, _Metadata, S) ->
    erlang:send_after(10, self(), {retry, N}),
    {ok, S}.
handle_info({retry, N}, S) ->
    evoq_replay_probe:record(info_received, N, #{}),
    {noreply, S#{last_retry => N}};
handle_info(stop_please, S) ->
    {stop, normal, S}.
