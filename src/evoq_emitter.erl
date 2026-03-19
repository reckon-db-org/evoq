%% @doc Emitter behaviour for evoq.
%%
%% Emitters subscribe to domain events and publish them as integration
%% facts to external transports (pg or mesh). They translate domain events
%% into facts using an evoq_fact module and publish to the target transport.
%%
%% Emitters live in the source desk -- the desk that processes the command
%% producing the event. They are supervised by the desk supervisor.
%%
%% Naming convention: emit_{event}_to_{transport}
%%
%% == Required Callbacks ==
%%
%% - source_event() -> atom()
%% - fact_module() -> module()
%% - transport() -> pg | mesh
%% - emit(FactType, Payload, Metadata) -> ok | {error, Reason}
%%
%% @author rgfaber
-module(evoq_emitter).

%% Required callbacks

%% Which domain event type triggers this emitter (atom).
-callback source_event() -> atom().

%% Which evoq_fact module translates the domain event to a fact.
-callback fact_module() -> module().

%% Target transport for publication.
-callback transport() -> pg | mesh.

%% Publish the translated fact to the transport.
%% FactType is the binary fact type from the fact module.
%% Payload is the translated map with binary keys.
%% Metadata is the original event metadata.
-callback emit(FactType :: binary(), Payload :: map(), Metadata :: map()) ->
    ok | {error, Reason :: term()}.
