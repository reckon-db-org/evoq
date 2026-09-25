%% @doc read_all_global/3 on an adapter without the optional callback must
%% still honour Offset and BatchSize.
%%
%% Every caller pages it: read a batch at Offset, advance Offset by what came
%% back, stop on a short page. The fallback read the whole store every time,
%% whatever Offset asked for, so a store of at least one batch never produced
%% a short page and the pager went round forever. And it returned maps, which
%% the store subscription does not route: records are the callback's type.
%%
%% This module is its own adapter: it exports only list_streams/1 and
%% read_all/3, the callbacks the fallback uses.
-module(evoq_read_all_global_fallback_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_types.hrl").

-export([list_streams/1, read_all/3]).

%% Two streams, interleaved in global order: a0 b0 a1 b1 a2.
list_streams(_StoreId) -> {ok, [<<"a">>, <<"b">>]}.

read_all(_StoreId, <<"a">>, forward) -> {ok, [event(<<"a">>, V, 2 * V) || V <- [0, 1, 2]]};
read_all(_StoreId, <<"b">>, forward) -> {ok, [event(<<"b">>, V, 2 * V + 1) || V <- [0, 1]]}.

event(Stream, Version, Pos) ->
    #evoq_event{event_id = <<Stream/binary, (integer_to_binary(Version))/binary>>,
                event_type = <<"fallback_probe_v1">>, stream_id = Stream,
                version = Version, data = #{}, metadata = #{}, tags = undefined,
                timestamp = Pos, epoch_us = Pos}.

fallback_pages_by_offset_and_batch_size_test_() ->
    {setup,
     fun() ->
         Old = application:get_env(evoq, event_store_adapter),
         evoq_event_store:set_adapter(?MODULE),
         Old
     end,
     fun({ok, Old}) -> evoq_event_store:set_adapter(Old);
        (undefined) -> application:unset_env(evoq, event_store_adapter)
     end,
     [?_assertEqual([<<"a0">>, <<"b0">>], ids(0, 2)),
      ?_assertEqual([<<"a1">>, <<"b1">>], ids(2, 2)),
      ?_assertEqual([<<"a2">>], ids(4, 2)),
      ?_assertEqual([], ids(5, 2))]}.

ids(Offset, BatchSize) ->
    {ok, Events} = evoq_event_store:read_all_global(fallback_store, Offset, BatchSize),
    %% Records, as from an adapter's own read_all_global/3: the store
    %% subscription routes nothing else. A map comes out as {not_a_record, _}.
    [id(E) || E <- Events].

id(#evoq_event{event_id = Id}) -> Id;
id(Other) -> {not_a_record, Other}.
