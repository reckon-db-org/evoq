%% @doc A handler on `restart_b_v1' that records each event under the name
%% it was started with, so two instances of it on one type can be told
%% apart (see evoq_per_registrant_backfill_tests).
-module(evoq_named_probe_b_handler).
-behaviour(evoq_event_handler).
-export([interested_in/0, init/1, handle_event/4, replay_policy/0]).

interested_in() -> [<<"restart_b_v1">>].
init(#{name := Name}) -> {ok, Name}.
handle_event(_Type, #{data := #{n := N}}, Metadata, Name) ->
    evoq_replay_probe:record(Name, N, Metadata),
    {ok, Name}.
replay_policy() -> deliver.
