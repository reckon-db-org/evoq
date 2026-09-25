%% @doc A checkpoint store that survives a restart, as a real persistent
%% store does: it keeps checkpoints in persistent_term, which no evoq
%% process owns.
-module(evoq_restart_probe_checkpoint_store).
-behaviour(evoq_checkpoint_store).
-export([load/1, save/2, delete/1, reset/0]).

load(Name) ->
    case persistent_term:get({?MODULE, Name}, undefined) of
        undefined -> {error, not_found};
        Checkpoint -> {ok, Checkpoint}
    end.

save(Name, Checkpoint) ->
    persistent_term:put({?MODULE, Name}, Checkpoint),
    ok.

delete(Name) ->
    _ = persistent_term:erase({?MODULE, Name}),
    ok.

reset() ->
    [persistent_term:erase(K) || {{?MODULE, _} = K, _} <- persistent_term:get()],
    ok.
