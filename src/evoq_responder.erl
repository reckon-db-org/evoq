%% @doc Responder behaviour for evoq.
%%
%% Responders receive hopes (via mesh or hecate:// API), dispatch commands
%% to the local aggregate, and return feedback containing the post-event
%% aggregate state. This enables session-level consistency for RPC.
%%
%% Naming convention: {command}_responder_v1
%%
%% == Required Callbacks ==
%%
%% - hope_type() -> binary()
%% - handle_hope(HopeType, Payload, Metadata) -> {ok, State} | {error, Reason}
%%
%% == Optional Callbacks ==
%%
%% - feedback_module() -> module()
%%
%% @author rgfaber
-module(evoq_responder).

%% Required callbacks

%% Which hope type this responder handles (binary topic).
-callback hope_type() -> binary().

%% Handle an incoming hope. Typically translates the hope payload into
%% a command, dispatches it, and returns the post-event aggregate state
%% as feedback for session-level consistency.
-callback handle_hope(HopeType :: binary(), Payload :: map(), Metadata :: map()) ->
    {ok, State :: term()} | {error, Reason :: term()}.

%% Optional callbacks

%% Which evoq_feedback module serializes the response.
-callback feedback_module() -> module().

-optional_callbacks([feedback_module/0]).
