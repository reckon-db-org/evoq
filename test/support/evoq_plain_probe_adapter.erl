%% @doc An event store adapter with no new_stream_id/1, the shape of every
%% adapter written before the callback existed. Asking it to mint must say
%% so, naming the adapter, rather than fail as an undef deep in a caller.
%% No -behaviour(evoq_adapter): this module exists to be incomplete.
-module(evoq_plain_probe_adapter).

-export([append/4]).

append(_StoreId, _StreamId, _ExpectedVersion, _Events) ->
    {ok, 0}.
