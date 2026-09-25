%% @doc A decision's context is either whole or refused (evoq #6, part one).
%%
%% The store's reads by tag, by event type and by payload return at most
%% their limit, the OLDEST matching events, and cannot page. A decision
%% whose context has more matching events than that folded only the oldest
%% and never saw the recent ones, silently. Until the store can page these
%% reads, load_context/2 asks for one event more than the context limit and
%% refuses with {context_truncated, Filter, Limit} when it gets it.
%%
%% The store is mocked as reckon-db behaves: the first Limit matching
%% events in global order.
-module(evoq_decision_context_truncation_tests).

-include_lib("eunit/include/eunit.hrl").

-define(STORE, truncation_test_store).
-define(LIMIT, 1000).

context_reads_test_() ->
    {foreach, fun setup/0, fun cleanup/1,
     [fun(_) -> {Name, fun() -> check(Filter) end} end
      || {Name, Filter} <- filters()]}.

filters() ->
    [{"any_of", {any_of, [<<"t">>]}},
     {"all_of", {all_of, [<<"t">>]}},
     {"event_type", {event_type, <<"placed_v1">>}},
     {"payload_match", {payload_match, <<"k">>, <<"v">>}},
     {"payload_hash_match", {payload_hash_match, [<<"k">>], [<<"v">>]}},
     {"compound", {or_, [{any_of, [<<"t">>]}, {event_type, <<"placed_v1">>}]}}].

%% One more matching event than the limit is refused, naming the filter and
%% the limit; exactly the limit is a whole context and goes through.
check(Filter) ->
    seed(?LIMIT + 500),
    ?assertEqual({error, {context_truncated, Filter, ?LIMIT}},
                 evoq_decision_runtime:load_context(?STORE, Filter)),
    seed(?LIMIT),
    {ok, Events, Cutoff} = evoq_decision_runtime:load_context(?STORE, Filter),
    ?assertEqual(?LIMIT, length(Events)),
    ?assertEqual(?LIMIT - 1, Cutoff).

setup() ->
    application:set_env(evoq, event_store_adapter, mock_adapter),
    meck:new(evoq_event_store, [passthrough]),
    Read = fun(Limit) -> {ok, lists:sublist(persistent_term:get({?MODULE, events}), Limit)} end,
    meck:expect(evoq_event_store, read_by_tags, fun(_, _, _, Limit) -> Read(Limit) end),
    meck:expect(evoq_event_store, read_events_by_types, fun(_, _, Limit) -> Read(Limit) end),
    meck:expect(evoq_event_store, ccc_read_by_payload, fun(_, _, _, Limit) -> Read(Limit) end),
    meck:expect(evoq_event_store, ccc_read_by_payload_hash, fun(_, _, _, Limit) -> Read(Limit) end),
    meck:expect(evoq_event_store, payload_indexes, fun(_) -> {ok, [<<"k">>]} end),
    meck:expect(evoq_event_store, payload_hash_indexes, fun(_) -> {ok, [[<<"k">>]]} end),
    ok.

cleanup(_) ->
    meck:unload(evoq_event_store),
    application:unset_env(evoq, event_store_adapter),
    persistent_term:erase({?MODULE, events}).

%% N DCB events matching every filter above, oldest first.
seed(N) ->
    persistent_term:put({?MODULE, events},
                        [#{event_id => integer_to_binary(V), event_type => <<"placed_v1">>,
                           stream_id => <<"_dcb">>, version => V, tags => [<<"t">>],
                           data => #{<<"k">> => <<"v">>}}
                         || V <- lists:seq(0, N - 1)]).
