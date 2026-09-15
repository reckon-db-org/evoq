%% @doc Minimal in-memory event store adapter for exercising the
%% checkpointed consumer's catch-up without a live reckon-db. Serves
%% #evoq_event{} records in global order and supports appends, so a test
%% can seed history, restart a handler, and append "live" events.
-module(evoq_fake_store).

-include_lib("evoq/include/evoq_types.hrl").

%% Test API
-export([reset/0, seed/1, append/1, event/3]).
%% evoq_event_store adapter surface used by the checkpointed consumer
-export([read_all_global/3]).

reset() ->
    ensure(),
    ets:insert(?MODULE, {events, []}),
    ok.

seed(Events) ->
    ensure(),
    ets:insert(?MODULE, {events, Events}),
    ok.

append(Events) ->
    ensure(),
    ets:insert(?MODULE, {events, current() ++ Events}),
    ok.

%% @doc Build an #evoq_event{} of the given type/id at a global position,
%% with epoch_us derived from the position so global order is unambiguous.
event(Type, Id, Position) ->
    #evoq_event{
        event_id = Id,
        event_type = Type,
        stream_id = <<"stream-", Id/binary>>,
        version = Position,
        data = #{},
        metadata = #{},
        tags = [],
        timestamp = Position,
        epoch_us = Position
    }.

%% @doc Return events from global index Offset (0-based), up to BatchSize.
read_all_global(_StoreId, Offset, BatchSize) ->
    Events = current(),
    Len = length(Events),
    slice(Offset >= Len, Events, Offset, BatchSize, Len).

slice(true, _Events, _Offset, _BatchSize, _Len) ->
    {ok, []};
slice(false, Events, Offset, BatchSize, Len) ->
    Last = min(Offset + BatchSize, Len),
    {ok, lists:sublist(Events, Offset + 1, Last - Offset)}.

current() ->
    case ets:lookup(?MODULE, events) of
        [{events, Es}] -> Es;
        [] -> []
    end.

ensure() ->
    case ets:whereis(?MODULE) of
        undefined -> ets:new(?MODULE, [named_table, public, set]);
        _ -> ok
    end.
