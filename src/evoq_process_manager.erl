%% @doc Process manager behavior for evoq.
%%
%% Process managers coordinate long-running business processes
%% that span multiple aggregates. They:
%% - Subscribe to events by type
%% - Correlate events to process instances
%% - Dispatch commands based on events
%% - Support compensation when a dispatched command fails
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
%%   Generate compensating commands when a dispatched command fails
%%
%% - handle_info(Info, State) -> handle_info_result()
%%   Any other message this process manager's instance receives, most
%%   usefully one it scheduled to itself from handle/3 (a clock deadline via
%%   erlang:send_after). The instance ignored every such message, so a PM
%%   with a deadline of its own had no way to be woken by it. Commands
%%   returned here are dispatched exactly as handle/3's are. The atom
%%   `timeout' is evoq's own idle timer and is never forwarded, so pick any
%%   other tag. A PM without this callback that is sent a message logs a
%%   warning naming itself and the message.
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

%% Same shape as gen_server's, with the PM's own state in place of the
%% gen_server state: the commands are dispatched as handle/3's are, and
%% stop ends the instance (the process has reached its end, or found that
%% it cannot continue).
-type handle_info_result() ::
    {noreply, NewState :: term()} |
    {noreply, NewState :: term(), Commands :: [#evoq_command{}]} |
    {stop, Reason :: term(), NewState :: term()}.

-export_type([correlation_result/0, handle_result/0, compensation_result/0,
              handle_info_result/0]).

%% Required callbacks
-callback interested_in() -> [EventType :: binary()].

-callback correlate(Event :: map(), Metadata :: map()) -> correlation_result().

-callback handle(State :: term(), Event :: map(), Metadata :: map()) -> handle_result().

-callback apply(State :: term(), Event :: map()) -> NewState :: term().

%% Optional callbacks
-callback compensate(State :: term(), FailedCommand :: #evoq_command{}) -> compensation_result().

-callback init(ProcessId :: binary()) -> {ok, State :: term()}.

-callback handle_info(Info :: term(), State :: term()) -> handle_info_result().

-optional_callbacks([compensate/2, init/1, handle_info/2]).

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
