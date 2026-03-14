%% @doc Event behavior for evoq.
%%
%% Events represent facts that have happened. They are:
%% - Past tense: account_opened, money_deposited
%% - Immutable once stored
%% - Produced by aggregates in response to commands
%% - Domain artifacts: atom keys, Erlang terms, stay inside bounded context
%%
%% == Required Callbacks ==
%%
%% - event_type() -> atom()
%% - new(Params) -> Event
%% - to_map(Event) -> map()
%%
%% == Optional Callbacks ==
%%
%% - from_map(Map) -> {ok, Event} | {error, Reason}
%%
%% @author rgfaber
-module(evoq_event).

%% Required callbacks
-callback event_type() -> atom().
-callback new(Params :: map()) -> Event :: term().
-callback to_map(Event :: term()) -> map().

%% Optional callbacks
-callback from_map(Map :: map()) -> {ok, Event :: term()} | {error, Reason :: term()}.

-optional_callbacks([from_map/1]).
