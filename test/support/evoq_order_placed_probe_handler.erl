%% @doc An event handler on pm_order_placed_v1, for the case where a handler
%% and a process manager share a type.
-module(evoq_order_placed_probe_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"pm_order_placed_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, #{data := #{order := Id}}, Metadata, S) ->
    evoq_replay_probe:record(placed_handler, Id, Metadata),
    {ok, S}.
replay_policy() -> deliver.
