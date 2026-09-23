%% @doc A side-effecting handler that declares it must not see replay.
-module(evoq_replay_probe_skip_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"replay_probe_v1">>].
init(_) -> {ok, #{}}.
replay_policy() -> skip.
handle_event(_Type, #{data := #{n := N}}, Metadata, S) ->
    evoq_replay_probe:record(skip_handler, N, Metadata),
    {ok, S}.
