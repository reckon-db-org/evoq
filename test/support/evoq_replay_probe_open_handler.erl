%% @doc A handler that declares no replay policy, as every handler written
%% before replay_policy/0 existed does. It keeps receiving replay.
-module(evoq_replay_probe_open_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"replay_probe_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, #{data := #{n := N}}, Metadata, S) ->
    evoq_replay_probe:record(open_handler, N, Metadata),
    {ok, S}.
