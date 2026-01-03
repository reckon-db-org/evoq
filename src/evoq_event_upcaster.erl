%% @doc Event upcaster behavior for schema evolution.
%%
%% Upcasters transform old event versions to the current version,
%% enabling backwards-compatible schema changes.
%%
%% == Usage ==
%%
%% 1. Create an upcaster module for each event type that needs transformation
%% 2. Implement upcast/2 to transform the event
%% 3. Register the upcaster with evoq_type_provider
%%
%% == Example ==
%%
%% ```
%% -module(account_created_v1_upcaster).
%% -behaviour(evoq_event_upcaster).
%%
%% -export([upcast/2, version/0]).
%%
%% version() -> 1.
%%
%% upcast(#{event_type := <<"AccountCreated">>, data := Data} = Event, _Meta) ->
%%     %% Add default email if missing (v1 -> v2)
%%     NewData = maps:put(email, <<"unknown@example.com">>, Data),
%%     {ok, Event#{data := NewData}}.
%% '''
%%
%% @author rgfaber
-module(evoq_event_upcaster).

%% Required callbacks
-callback upcast(Event :: map(), Metadata :: map()) ->
    {ok, TransformedEvent :: map()} |
    {ok, TransformedEvent :: map(), NewEventType :: binary()} |
    skip.

%% Optional callbacks
-callback version() -> pos_integer().

-optional_callbacks([version/0]).

%% API
-export([upcast/3]).
-export([chain_upcasters/3]).

%%====================================================================
%% API
%%====================================================================

%% @doc Apply a single upcaster to an event.
-spec upcast(atom(), map(), map()) -> {ok, map()} | {ok, map(), binary()} | skip.
upcast(UpcasterModule, Event, Metadata) ->
    UpcasterModule:upcast(Event, Metadata).

%% @doc Apply a chain of upcasters to an event.
%% Upcasters are applied in order. Each upcaster transforms
%% the event for the next one in the chain.
-spec chain_upcasters([atom()], map(), map()) -> {ok, map()} | {ok, map(), binary()} | skip.
chain_upcasters([], Event, _Metadata) ->
    {ok, Event};
chain_upcasters([Upcaster | Rest], Event, Metadata) ->
    case upcast(Upcaster, Event, Metadata) of
        {ok, TransformedEvent} ->
            chain_upcasters(Rest, TransformedEvent, Metadata);
        {ok, TransformedEvent, NewEventType} ->
            %% Event type changed - continue with new type
            {ok, TransformedEvent#{event_type => NewEventType}, NewEventType};
        skip ->
            skip
    end.
