%% @doc A handler on `restart_b_v1', present in one boot and absent in the
%% next: its presence changes how the store subscription numbers events.
-module(evoq_restart_probe_b_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"restart_b_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, _Event, _Metadata, S) -> {ok, S}.
replay_policy() -> deliver.
