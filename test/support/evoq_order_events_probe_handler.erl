%% @doc An event handler on both order probe types. Until a process manager
%% can hold a type on its own (evoq #2), the store subscription routes a
%% type only when a handler consumes it; this one does, and records nothing.
-module(evoq_order_events_probe_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"pm_order_placed_v1">>, <<"pm_order_paid_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, _Event, _Metadata, S) -> {ok, S}.
replay_policy() -> deliver.
