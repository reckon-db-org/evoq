%% @doc Process manager (saga) behavior for evoq.
%%
%% Process managers coordinate long-running business processes
%% that span multiple aggregates. They:
%% - Subscribe to events by type
%% - Correlate events to process instances
%% - Dispatch commands based on events
%% - Support compensation for saga rollback
%%
%% == Callbacks ==
%%
%% Required:
%% - interested_in() -> [binary()]
%%   Event types this PM processes
%%
%% - correlate(Event, Metadata) -> correlation_result()
%%   Determines process instance for an event
%%
%% - handle(State, Event, Metadata) -> handle_result()
%%   Process the event and optionally dispatch commands
%%
%% - apply(State, Event) -> NewState
%%   Apply event to process manager state
%%
%% Optional:
%% - compensate(State, FailedCommand) -> compensation_result()
%%   Generate compensating commands for saga rollback
%%
%% == Example ==
%%
%% ```
%% -module(order_fulfillment_pm).
%% -behaviour(evoq_process_manager).
%%
%% interested_in() -> [<<"OrderPlaced">>, <<"PaymentReceived">>, <<"ItemShipped">>].
%%
%% correlate(#{data := #{order_id := OrderId}}, _Meta) ->
%%     {continue, OrderId}.
%%
%% handle(State, #{event_type := <<"OrderPlaced">>} = Event, _Meta) ->
%%     %% Start payment process
%%     Cmd = evoq_command:new(process_payment, payment, OrderId, #{...}),
%%     {ok, State, [Cmd]}.
%% '''
%%
%% @author rgfaber
-module(evoq_process_manager).

-include("evoq.hrl").

%% Types
-type correlation_result() ::
    {start, ProcessId :: binary()} |
    {continue, ProcessId :: binary()} |
    {stop, ProcessId :: binary()} |
    false.

-type handle_result() ::
    {ok, NewState :: term()} |
    {ok, NewState :: term(), Commands :: [#evoq_command{}]} |
    {error, Reason :: term()}.

-type compensation_result() ::
    {ok, CompensatingCommands :: [#evoq_command{}]} |
    skip.

-export_type([correlation_result/0, handle_result/0, compensation_result/0]).

%% Required callbacks
-callback interested_in() -> [EventType :: binary()].

-callback correlate(Event :: map(), Metadata :: map()) -> correlation_result().

-callback handle(State :: term(), Event :: map(), Metadata :: map()) -> handle_result().

-callback apply(State :: term(), Event :: map()) -> NewState :: term().

%% Optional callbacks
-callback compensate(State :: term(), FailedCommand :: #evoq_command{}) -> compensation_result().

-callback init(ProcessId :: binary()) -> {ok, State :: term()}.

-optional_callbacks([compensate/2, init/1]).

%% API
-export([start/2, start/3]).
-export([get_event_types/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Register a process manager (start subscription).
-spec start(atom(), map()) -> ok.
start(PMModule, _Config) ->
    start(PMModule, #{}, #{}).

%% @doc Register a process manager with options.
%% This registers the PM module with the router so it receives events.
-spec start(atom(), map(), map()) -> ok.
start(PMModule, _Config, _Opts) ->
    evoq_pm_router:register_pm(PMModule).

%% @doc Get event types this process manager is interested in.
-spec get_event_types(atom()) -> [binary()].
get_event_types(PMModule) ->
    PMModule:interested_in().
