%% @doc Hope behavior for evoq.
%%
%% Hopes are integration artifacts for outbound RPC requests between
%% agents or bounded contexts. Unlike facts (fire-and-forget), hopes
%% expect a response.
%%
%% Key characteristics:
%% - Binary keys (JSON-safe), serializable for transport
%% - Represent a request/intention directed at another agent
%% - Cross boundary via mesh RPC or similar transport
%% - Named "hope" because the caller hopes for a response but
%%   cannot guarantee one (distributed systems reality)
%%
%% == Required Callbacks ==
%%
%% - hope_type() -> binary()
%% - new(Params) -> {ok, Hope} | {error, Reason}
%% - to_payload(Hope) -> map()
%% - from_payload(Payload) -> {ok, Hope} | {error, Reason}
%%
%% == Optional Callbacks ==
%%
%% - validate(Hope) -> ok | {error, Reason}
%% - serialize(Payload) -> {ok, binary()} | {error, Reason}
%% - deserialize(Binary) -> {ok, map()} | {error, Reason}
%% - schema() -> map()
%%
%% @author rgfaber
-module(evoq_hope).

%% Required callbacks
-callback hope_type() -> binary().
-callback new(Params :: map()) -> {ok, Hope :: term()} | {error, Reason :: term()}.
-callback to_payload(Hope :: term()) -> map().
-callback from_payload(Payload :: map()) -> {ok, Hope :: term()} | {error, Reason :: term()}.

%% Optional callbacks
-callback validate(Hope :: term()) -> ok | {error, Reason :: term()}.
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason :: term()}.
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason :: term()}.
-callback schema() -> map().

-optional_callbacks([validate/1, serialize/1, deserialize/1, schema/0]).

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
