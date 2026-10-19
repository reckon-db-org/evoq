%% @doc A stream id can be minted through evoq, without reaching below it.
%%
%% evoq had no minting API at all, so a service that needs a fresh aggregate
%% id (a game, a session) had to reach past evoq to the store layer and
%% hand-roll an id in the store's private format. The id is the backend's
%% contract, so evoq asks the adapter: new_stream_id/1 is an optional
%% evoq_adapter callback, exposed as evoq_event_store:new_stream_id/1. An
%% adapter that does not implement it is named in an error rather than
%% failing as an undef somewhere under the caller's command handler.
-module(evoq_event_store_new_stream_id_tests).

-include_lib("eunit/include/eunit.hrl").

%% The prefix reaches the adapter unchanged, and the adapter's answer is
%% what the caller gets.
the_adapter_mints_the_id_test() ->
    with_adapter(evoq_minting_probe_adapter, fun() ->
        evoq_minting_probe_adapter:reset(),
        ?assertEqual(<<"game-0123456789abcdef0123456789abcdef">>,
                     evoq_event_store:new_stream_id(<<"game">>)),
        ?assertEqual(binary, evoq_minting_probe_adapter:asked())
    end).

%% An atom prefix is passed through as an atom: the adapter decides what a
%% prefix is, and the store's own generator takes either.
an_atom_prefix_reaches_the_adapter_as_an_atom_test() ->
    with_adapter(evoq_minting_probe_adapter, fun() ->
        evoq_minting_probe_adapter:reset(),
        ?assertEqual(<<"game-0123456789abcdef0123456789abcdef">>,
                     evoq_event_store:new_stream_id(game)),
        ?assertEqual(atom, evoq_minting_probe_adapter:asked())
    end).

%% The refusal names the adapter that cannot mint, so the fix is obvious.
an_adapter_without_minting_is_named_test() ->
    with_adapter(evoq_plain_probe_adapter, fun() ->
        ?assertError({adapter_cannot_mint_stream_ids, evoq_plain_probe_adapter},
                     evoq_event_store:new_stream_id(<<"game">>))
    end).

%% An adapter that is configured but not loaded still mints. Minting a new
%% game's id is the call that comes BEFORE the first append, so under
%% interactive code loading (a shell, eunit, ct, a mix dev node) the adapter
%% can easily be unloaded at that moment; function_exported/3 answers false
%% for an unloaded module, and the caller would be told its adapter cannot
%% mint when it can. A release in embedded mode hides this; a test node does
%% not.
an_adapter_is_loaded_before_it_is_asked_to_mint_test() ->
    with_adapter(evoq_lazy_probe_adapter, fun() ->
        unload(evoq_lazy_probe_adapter),
        ?assertEqual(<<"lazy-game-0123456789abcdef0123456789abcdef">>,
                     evoq_event_store:new_stream_id(<<"game">>))
    end).

%%====================================================================
%% Helpers
%%====================================================================

%% Leave the module neither loaded nor on the code path's loaded set, so the
%% next call has nothing but the module name to go on.
unload(Module) ->
    _ = code:purge(Module),
    _ = code:delete(Module),
    _ = code:purge(Module),
    ?assertEqual(false, erlang:module_loaded(Module)).

%% Set the adapter for one test and put back whatever was configured
%% before, so this module cannot change what the rest of the suite sees.
with_adapter(Adapter, Fun) ->
    Previous = application:get_env(evoq, event_store_adapter),
    ok = evoq_event_store:set_adapter(Adapter),
    try Fun()
    after restore_adapter(Previous)
    end.

restore_adapter({ok, Adapter}) -> ok = evoq_event_store:set_adapter(Adapter);
restore_adapter(undefined) -> application:unset_env(evoq, event_store_adapter).
