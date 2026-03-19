%% @doc Requester behaviour for evoq.
%%
%% Requesters send hopes over mesh and wait for feedback. Used for
%% cross-daemon RPC where the caller needs a response (session-level
%% consistency).
%%
%% Unlike emitters (fire-and-forget facts), requesters expect feedback
%% from the remote responder containing the result of command execution.
%%
%% Naming convention: request_{hope_type}
%%
%% == Required Callbacks ==
%%
%% - hope_module() -> module()
%% - send(Hope, Opts) -> {ok, Feedback} | {error, Reason}
%%
%% @author rgfaber
-module(evoq_requester).

%% Required callbacks

%% Which evoq_hope module defines the hope being sent.
-callback hope_module() -> module().

%% Send a hope and wait for feedback.
%% Hope is the constructed hope term.
%% Opts may include timeout, retry config, etc.
%% Returns feedback from the remote responder.
-callback send(Hope :: term(), Opts :: map()) ->
    {ok, Feedback :: map()} | {error, Reason :: term()}.
