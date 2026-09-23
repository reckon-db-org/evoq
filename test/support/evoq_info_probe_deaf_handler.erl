%% @doc A handler with no handle_info/2 at all.
-module(evoq_info_probe_deaf_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"info_probe_deaf_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, _Event, _Metadata, S) -> {ok, S}.
