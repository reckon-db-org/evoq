%%% @doc Unit tests for the stateful decision actor (Part B).
%%%
%%% Starts a real evoq_decisions_sup (registry + partition sups) and
%%% meck-mocks evoq_event_store, so the facade routing
%%% (evoq_decision_runtime:dispatch/3 -> boundary_key -> actor) and the
%%% actor's cache/serialise/invalidate behaviour are exercised end to end
%%% without a reckon-db backend.
%%% @end
-module(evoq_decision_actor_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, decision_actor_test_store).

%%====================================================================
%% Decision modules (via meck)
%%====================================================================

%% Stateful, unfolded: boundary_key keys on the command's tag; decide
%% receives the raw context-events list.
stateful_unfolded_setup() ->
    meck:new(test_actor_unfolded, [non_strict]),
    meck:expect(test_actor_unfolded, boundary_key,
        fun(#{key := K}) -> K end),
    meck:expect(test_actor_unfolded, context,
        fun(#{key := K}) -> {any_of, [K]} end),
    meck:expect(test_actor_unfolded, decide,
        fun(_ContextEvents, #{key := K}) ->
            {ok, [#{event_type => <<"reserved">>, data => #{k => K}, tags => [K]}]}
        end).

%% Stateful, folded: maintains a count of context events as its model;
%% decide receives that integer model, not the raw list.
stateful_folded_setup() ->
    meck:new(test_actor_folded, [non_strict]),
    meck:expect(test_actor_folded, boundary_key, fun(#{key := K}) -> K end),
    meck:expect(test_actor_folded, context, fun(#{key := K}) -> {any_of, [K]} end),
    meck:expect(test_actor_folded, init_decision_model, fun() -> 0 end),
    meck:expect(test_actor_folded, apply_context_event, fun(N, _E) -> N + 1 end),
    meck:expect(test_actor_folded, decide,
        fun(_Model, #{key := K}) ->
            {ok, [#{event_type => <<"reserved">>, data => #{k => K}, tags => [K]}]}
        end).

%% Stateful with a short retry budget for the exhaustion test.
stateful_short_budget_setup() ->
    meck:new(test_actor_short, [non_strict]),
    meck:expect(test_actor_short, boundary_key, fun(#{key := K}) -> K end),
    meck:expect(test_actor_short, context, fun(#{key := K}) -> {any_of, [K]} end),
    meck:expect(test_actor_short, decide,
        fun(_Ctx, #{key := K}) ->
            {ok, [#{event_type => <<"e">>, data => #{}, tags => [K]}]}
        end),
    meck:expect(test_actor_short, retry_budget, fun() -> 2 end).

%% Stateless: boundary_key returns undefined -> no actor.
stateless_setup() ->
    meck:new(test_actor_stateless, [non_strict]),
    meck:expect(test_actor_stateless, boundary_key, fun(_) -> undefined end),
    meck:expect(test_actor_stateless, context, fun(_) -> {any_of, [<<"s">>]} end),
    meck:expect(test_actor_stateless, decide,
        fun(_Ctx, _Cmd) ->
            {ok, [#{event_type => <<"e">>, data => #{}, tags => [<<"s">>]}]}
        end).

%%====================================================================
%% Setup / Teardown
%%====================================================================

setup() ->
    application:set_env(evoq, event_store_adapter, mock_adapter),
    meck:new(evoq_event_store, [passthrough]),
    {ok, SupPid} = evoq_decisions_sup:start_link(),
    SupPid.

cleanup(SupPid) ->
    application:unset_env(evoq, event_store_adapter),
    catch meck:unload(evoq_event_store),
    catch meck:unload(test_actor_unfolded),
    catch meck:unload(test_actor_folded),
    catch meck:unload(test_actor_short),
    catch meck:unload(test_actor_stateless),
    stop_sup(SupPid),
    ok.

stop_sup(SupPid) ->
    Ref = monitor(process, SupPid),
    unlink(SupPid),
    exit(SupPid, shutdown),
    receive {'DOWN', Ref, process, SupPid, _} -> ok
    after 2000 -> ok end.

%%====================================================================
%% Runner
%%====================================================================

all_test_() ->
    {foreach, fun setup/0, fun cleanup/1, [
        fun routes_to_actor_and_appends/0,
        fun caches_model_no_second_read/0,
        fun cutoff_advances_after_append/0,
        fun context_changed_reloads_and_retries/0,
        fun retry_budget_exhausts/0,
        fun folded_model_passed_to_decide/0,
        fun decide_error_propagates_no_append/0,
        fun payload_index_unavailable_fails_loud/0,
        fun undefined_boundary_key_starts_no_actor/0,
        fun distinct_keys_get_distinct_actors/0
    ]}.

%%====================================================================
%% Cases
%%====================================================================

routes_to_actor_and_appends() ->
    stateful_unfolded_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, _C, _E) -> {ok, 0} end),
    Result = dispatch(test_actor_unfolded, #{key => <<"seat:12A">>}),
    ?assertMatch({ok, [#{event_type := <<"reserved">>}]}, Result),
    %% An actor now exists for this boundary.
    ?assertMatch({ok, _},
        evoq_decision_registry:lookup(test_actor_unfolded, <<"seat:12A">>)).

caches_model_no_second_read() ->
    stateful_unfolded_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, _C, _E) -> {ok, 0} end),
    Cmd = #{key => <<"seat:1">>},
    {ok, _} = dispatch(test_actor_unfolded, Cmd),
    {ok, _} = dispatch(test_actor_unfolded, Cmd),
    %% Context read happens ONCE (lazy load on first decide); the second
    %% decide reuses the cached model.
    ?assertEqual(1, meck:num_calls(evoq_event_store, read_by_tags, '_')),
    ?assertEqual(2, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

cutoff_advances_after_append() ->
    stateful_unfolded_setup(),
    %% Initial context empty -> cutoff -1 on first append; store reports
    %% LastSeq 7; second append must see cutoff 7 (no re-read).
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    Seen = ets:new(seen, [public]),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, Cutoff, _E) ->
            ets:insert(Seen, {erlang:unique_integer([monotonic]), Cutoff}),
            {ok, 7}
        end),
    Cmd = #{key => <<"seat:2">>},
    {ok, _} = dispatch(test_actor_unfolded, Cmd),
    {ok, _} = dispatch(test_actor_unfolded, Cmd),
    Cutoffs = [C || {_, C} <- lists:sort(ets:tab2list(Seen))],
    ?assertEqual([-1, 7], Cutoffs).

context_changed_reloads_and_retries() ->
    stateful_unfolded_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    Counter = counters:new(1, []),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_S, _F, _C, _E) ->
            N = counters:get(Counter, 1),
            counters:add(Counter, 1, 1),
            case N of
                0 -> {error, {context_changed, 5}};
                _ -> {ok, 6}
            end
        end),
    Result = dispatch(test_actor_unfolded, #{key => <<"seat:3">>}),
    ?assertMatch({ok, _}, Result),
    %% One conflict -> one reload: 2 reads (initial + reload), 2 appends.
    ?assertEqual(2, meck:num_calls(evoq_event_store, read_by_tags, '_')),
    ?assertEqual(2, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

retry_budget_exhausts() ->
    stateful_short_budget_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {error, {context_changed, 99}} end),
    ?assertEqual({error, retry_budget_exhausted},
        dispatch(test_actor_short, #{key => <<"seat:4">>})),
    %% Budget 2 -> 2 append attempts.
    ?assertEqual(2, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')).

folded_model_passed_to_decide() ->
    stateful_folded_setup(),
    %% Two context events -> folded model = 2 (the count).
    Ev = #{event_type => <<"reserved">>, stream_id => <<"_dcb">>,
           version => 1, data => #{}, tags => [<<"seat:5">>]},
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, [Ev, Ev]} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {ok, 3} end),
    {ok, _} = dispatch(test_actor_folded, #{key => <<"seat:5">>}),
    %% decide saw the folded integer model (2 events folded), not a list.
    [[Model, _Cmd]] =
        [Args || {_Pid, {_M, decide, Args}, _Ret}
                 <- meck:history(test_actor_folded)],
    ?assertEqual(2, Model).

decide_error_propagates_no_append() ->
    meck:new(test_actor_reject, [non_strict]),
    meck:expect(test_actor_reject, boundary_key, fun(#{key := K}) -> K end),
    meck:expect(test_actor_reject, context, fun(#{key := K}) -> {any_of, [K]} end),
    meck:expect(test_actor_reject, decide, fun(_, _) -> {error, already_taken} end),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> ?assert(false), {ok, 0} end),
    ?assertEqual({error, already_taken},
        dispatch(test_actor_reject, #{key => <<"seat:6">>})),
    ?assertEqual(0, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')),
    catch meck:unload(test_actor_reject).

payload_index_unavailable_fails_loud() ->
    %% A keyed boundary whose context is a payload filter against an
    %% undeclared index must fail loud through the actor, never append.
    meck:new(test_actor_payload, [non_strict]),
    meck:expect(test_actor_payload, boundary_key, fun(#{key := K}) -> K end),
    meck:expect(test_actor_payload, context,
        fun(_) -> {payload_match, <<"license_key">>, <<"LK">>} end),
    meck:expect(test_actor_payload, decide, fun(_, _) -> {ok, []} end),
    meck:expect(evoq_event_store, payload_indexes, fun(_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> ?assert(false), {ok, 0} end),
    Result = dispatch(test_actor_payload, #{key => <<"k">>}),
    ?assertEqual({error, {payload_index_unavailable,
                          {payload_match, <<"license_key">>, <<"LK">>}}}, Result),
    ?assertEqual(0, meck:num_calls(evoq_event_store, append_if_no_tag_matches, '_')),
    catch meck:unload(test_actor_payload).

undefined_boundary_key_starts_no_actor() ->
    stateless_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {ok, 0} end),
    {ok, _} = dispatch(test_actor_stateless, #{}),
    %% Stateless path: no decision actor registered anywhere.
    ?assertEqual([], pg:which_groups(evoq_decision_pg)).

distinct_keys_get_distinct_actors() ->
    stateful_unfolded_setup(),
    meck:expect(evoq_event_store, read_by_tags, fun(_,_,_,_) -> {ok, []} end),
    meck:expect(evoq_event_store, append_if_no_tag_matches,
        fun(_,_,_,_) -> {ok, 0} end),
    {ok, _} = dispatch(test_actor_unfolded, #{key => <<"a">>}),
    {ok, _} = dispatch(test_actor_unfolded, #{key => <<"b">>}),
    {ok, PidA} = evoq_decision_registry:lookup(test_actor_unfolded, <<"a">>),
    {ok, PidB} = evoq_decision_registry:lookup(test_actor_unfolded, <<"b">>),
    ?assertNotEqual(PidA, PidB).

%%====================================================================
%% Helpers
%%====================================================================

dispatch(Mod, Cmd) ->
    evoq_decision_runtime:dispatch(Mod, ?STORE, Cmd).
