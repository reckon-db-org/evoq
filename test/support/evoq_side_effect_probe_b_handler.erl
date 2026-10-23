%% @doc A handler on `restart_b_v1' with a side effect it must not repeat
%% (a mesh publish, say): it declares `replay_policy() -> skip' and records
%% each side effect it performs.
-module(evoq_side_effect_probe_b_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"restart_b_v1">>].
init(_) -> {ok, #{}}.
handle_event(_Type, #{data := #{n := N}}, Metadata, S) ->
    evoq_replay_probe:record(side_effect, N, Metadata),
    {ok, S}.
replay_policy() -> skip.
