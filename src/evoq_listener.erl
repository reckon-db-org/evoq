%% @doc Listener behaviour for evoq.
%%
%% Listeners receive integration facts from external transports (pg or mesh)
%% and dispatch commands to the local aggregate. They are the entry point
%% for cross-domain integration.
%%
%% Listeners get their own slice directory in the target CMD app, like
%% process managers. This gives filesystem-level discoverability of
%% external integration points.
%%
%% Naming convention: on_{fact}_from_{transport}_{command}
%%
%% == Required Callbacks ==
%%
%% - source_fact() -> binary()
%% - transport() -> pg | mesh
%% - handle_fact(FactType, Payload, Metadata) -> ok | skip | {error, Reason}
%%
%% @author rgfaber
-module(evoq_listener).

%% Required callbacks

%% Which fact type this listener subscribes to (binary topic).
-callback source_fact() -> binary().

%% Source transport.
-callback transport() -> pg | mesh.

%% Handle a received fact. Typically translates the fact payload into
%% a command and dispatches it to the local aggregate.
%% Return ok if the command was dispatched, skip if the fact was
%% intentionally ignored, or {error, Reason} on failure.
-callback handle_fact(FactType :: binary(), Payload :: map(), Metadata :: map()) ->
    ok | skip | {error, Reason :: term()}.
