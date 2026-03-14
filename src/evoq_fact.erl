%% @doc Fact behavior for evoq.
%%
%% Facts are integration artifacts that cross bounded context boundaries.
%% They translate domain events into serializable payloads for external
%% consumption via pg (local) or mesh (WAN).
%%
%% Key differences from domain events:
%% - Binary keys (JSON-safe), not atom keys
%% - Explicit public contract, not internal implementation detail
%% - May have different structure/name than the source event
%% - Versioned independently from the domain event
%%
%% == Required Callbacks ==
%%
%% - fact_type() -> binary()
%% - from_event(EventType, EventData, Metadata) -> {ok, Payload} | skip
%%
%% == Optional Callbacks ==
%%
%% - serialize(Payload) -> {ok, binary()} | {error, Reason}
%% - deserialize(Binary) -> {ok, map()} | {error, Reason}
%% - schema() -> map()
%%
%% @author rgfaber
-module(evoq_fact).

%% Required callbacks
-callback fact_type() -> binary().
-callback from_event(EventType :: atom(), EventData :: map(), Metadata :: map()) ->
    {ok, Payload :: map()} | skip.

%% Optional callbacks
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason :: term()}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason :: term()}.
-callback schema() -> map().

-optional_callbacks([serialize/1, deserialize/1, schema/0]).

%% Default implementations
-export([default_serialize/1, default_deserialize/1]).

%% @doc Default serialization using OTP 27 json module.
-spec default_serialize(map()) -> {ok, binary()} | {error, term()}.
default_serialize(Payload) when is_map(Payload) ->
    try
        {ok, json:encode(Payload)}
    catch
        error:Reason -> {error, {json_encode_failed, Reason}}
    end.

%% @doc Default deserialization using OTP 27 json module.
-spec default_deserialize(binary()) -> {ok, map()} | {error, term()}.
default_deserialize(Binary) when is_binary(Binary) ->
    try
        {ok, json:decode(Binary)}
    catch
        error:Reason -> {error, {json_decode_failed, Reason}}
    end.
