%% @doc Feedback behaviour for evoq.
%%
%% Feedback is the response to a Hope. It carries the result of command
%% execution at the responder side, enabling session-level consistency.
%%
%% Success feedback contains the post-event aggregate state so the
%% requester has immediate truth without querying remote read models.
%%
%% Error feedback contains the reason for failure.
%%
%% Naming convention: {hope}_feedback_v1
%%
%% == Required Callbacks ==
%%
%% - feedback_type() -> binary()
%% - from_result(Result) -> map()
%% - to_result(Payload) -> {ok, term()} | {error, term()}
%%
%% == Optional Callbacks ==
%%
%% - serialize(Payload) -> {ok, binary()} | {error, Reason}
%% - deserialize(Binary) -> {ok, map()} | {error, Reason}
%%
%% @author rgfaber
-module(evoq_feedback).

%% Required callbacks

%% Feedback type identifier (binary).
-callback feedback_type() -> binary().

%% Convert a command execution result to a feedback payload.
%% The payload MUST have binary keys and be JSON-serializable.
%% The payload MUST include a <<"status">> key ("ok" or "error").
-callback from_result(Result :: {ok, State :: term()} | {error, Reason :: term()}) ->
    map().

%% Convert a received feedback payload back to a result.
-callback to_result(Payload :: map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

%% Optional callbacks

%% Custom serialization (defaults available via default_serialize/1).
-callback serialize(Payload :: map()) -> {ok, binary()} | {error, Reason :: term()}.
%% Custom deserialization (defaults available via default_deserialize/1).
-callback deserialize(Binary :: binary()) -> {ok, map()} | {error, Reason :: term()}.

-optional_callbacks([serialize/1, deserialize/1]).

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
