%% @doc Telemetry utilities for evoq.
%%
%% Provides helper functions for attaching telemetry handlers
%% and formatting telemetry events.
%%
%% == Event Naming Convention ==
%%
%% All events follow the pattern: [evoq, component, action, stage]
%% where stage is one of: start | stop | exception
%%
%% == Example Usage ==
%%
%% ```
%% %% Attach a handler for all aggregate events
%% evoq_telemetry:attach_aggregate_handlers(my_handler, fun handle_event/4).
%%
%% %% Attach a handler for specific events
%% evoq_telemetry:attach([evoq, aggregate, execute, start], my_handler, fun handle_event/4).
%% '''
%%
%% @author rgfaber
-module(evoq_telemetry).

-include("evoq_telemetry.hrl").

%% API
-export([attach/3, attach/4]).
-export([detach/1]).
-export([attach_aggregate_handlers/2]).
-export([attach_handler_handlers/2]).
-export([attach_projection_handlers/2]).
-export([attach_pm_handlers/2]).
-export([attach_all_handlers/2]).
-export([list_handlers/0]).

%% Span helpers
-export([span/3]).

%%====================================================================
%% API
%%====================================================================

%% @doc Attach a telemetry handler.
-spec attach(atom() | [atom(), ...], atom(), fun(([atom(), ...], map(), map(), term()) -> term())) -> ok | {error, already_exists}.
attach(EventName, HandlerId, HandlerFun) ->
    attach(EventName, HandlerId, HandlerFun, #{}).

%% @doc Attach a telemetry handler with config.
-spec attach(atom() | [atom(), ...], atom(), fun(([atom(), ...], map(), map(), term()) -> term()), map()) -> ok | {error, already_exists}.
attach(EventName, HandlerId, HandlerFun, Config) when is_atom(EventName) ->
    attach([EventName], HandlerId, HandlerFun, Config);
attach(EventName, HandlerId, HandlerFun, Config) when is_list(EventName) ->
    telemetry:attach(HandlerId, EventName, HandlerFun, Config).

%% @doc Detach a telemetry handler.
-spec detach(atom()) -> ok | {error, not_found}.
detach(HandlerId) ->
    telemetry:detach(HandlerId).

%% @doc Attach handlers for all aggregate telemetry events.
-spec attach_aggregate_handlers(atom(), fun()) -> ok.
attach_aggregate_handlers(HandlerIdPrefix, HandlerFun) ->
    Events = [
        ?TELEMETRY_AGGREGATE_EXECUTE_START,
        ?TELEMETRY_AGGREGATE_EXECUTE_STOP,
        ?TELEMETRY_AGGREGATE_EXECUTE_EXCEPTION,
        ?TELEMETRY_AGGREGATE_INIT,
        ?TELEMETRY_AGGREGATE_HIBERNATE,
        ?TELEMETRY_AGGREGATE_PASSIVATE,
        ?TELEMETRY_AGGREGATE_ACTIVATE,
        ?TELEMETRY_AGGREGATE_SNAPSHOT_SAVE,
        ?TELEMETRY_AGGREGATE_SNAPSHOT_LOAD
    ],
    attach_events(HandlerIdPrefix, Events, HandlerFun).

%% @doc Attach handlers for all event handler telemetry events.
-spec attach_handler_handlers(atom(), fun()) -> ok.
attach_handler_handlers(HandlerIdPrefix, HandlerFun) ->
    Events = [
        ?TELEMETRY_HANDLER_START,
        ?TELEMETRY_HANDLER_STOP,
        ?TELEMETRY_HANDLER_EXCEPTION,
        ?TELEMETRY_HANDLER_EVENT_START,
        ?TELEMETRY_HANDLER_EVENT_STOP,
        ?TELEMETRY_HANDLER_EVENT_EXCEPTION,
        ?TELEMETRY_HANDLER_RETRY,
        ?TELEMETRY_HANDLER_DEAD_LETTER
    ],
    attach_events(HandlerIdPrefix, Events, HandlerFun).

%% @doc Attach handlers for all projection telemetry events.
-spec attach_projection_handlers(atom(), fun()) -> ok.
attach_projection_handlers(HandlerIdPrefix, HandlerFun) ->
    Events = [
        ?TELEMETRY_PROJECTION_START,
        ?TELEMETRY_PROJECTION_STOP,
        ?TELEMETRY_PROJECTION_EVENT,
        ?TELEMETRY_PROJECTION_EXCEPTION,
        ?TELEMETRY_PROJECTION_CHECKPOINT
    ],
    attach_events(HandlerIdPrefix, Events, HandlerFun).

%% @doc Attach handlers for all process manager telemetry events.
-spec attach_pm_handlers(atom(), fun()) -> ok.
attach_pm_handlers(HandlerIdPrefix, HandlerFun) ->
    Events = [
        ?TELEMETRY_PM_START,
        ?TELEMETRY_PM_STOP,
        ?TELEMETRY_PM_COMMAND,
        ?TELEMETRY_PM_COMPENSATE
    ],
    attach_events(HandlerIdPrefix, Events, HandlerFun).

%% @doc Attach handlers for ALL evoq telemetry events.
-spec attach_all_handlers(atom(), fun()) -> ok.
attach_all_handlers(HandlerIdPrefix, HandlerFun) ->
    attach_aggregate_handlers(HandlerIdPrefix, HandlerFun),
    attach_handler_handlers(HandlerIdPrefix, HandlerFun),
    attach_projection_handlers(HandlerIdPrefix, HandlerFun),
    attach_pm_handlers(HandlerIdPrefix, HandlerFun),
    %% Additional events
    Events = [
        ?TELEMETRY_DISPATCH_START,
        ?TELEMETRY_DISPATCH_STOP,
        ?TELEMETRY_DISPATCH_EXCEPTION,
        ?TELEMETRY_MIDDLEWARE_BEFORE,
        ?TELEMETRY_MIDDLEWARE_AFTER,
        ?TELEMETRY_MIDDLEWARE_FAILURE,
        ?TELEMETRY_IDEMPOTENCY_HIT,
        ?TELEMETRY_IDEMPOTENCY_MISS,
        ?TELEMETRY_ROUTING_EVENT,
        ?TELEMETRY_ROUTING_UPCAST,
        ?TELEMETRY_MEMORY_PRESSURE,
        ?TELEMETRY_MEMORY_TTL_ADJUSTED
    ],
    attach_events(HandlerIdPrefix, Events, HandlerFun).

%% @doc List all attached handlers.
-spec list_handlers() -> [map()].
list_handlers() ->
    telemetry:list_handlers([evoq]).

%% @doc Execute a function within a telemetry span.
%% Emits start and stop (or exception) events.
-spec span([atom()], map(), fun(() -> term())) -> term().
span(EventPrefix, Metadata, Fun) ->
    StartTime = erlang:system_time(microsecond),

    %% Emit start event
    telemetry:execute(EventPrefix ++ [start], #{
        system_time => StartTime
    }, Metadata),

    try Fun() of
        Result ->
            StopDuration = erlang:system_time(microsecond) - StartTime,

            %% Emit stop event
            telemetry:execute(EventPrefix ++ [stop], #{
                duration => StopDuration
            }, Metadata),

            Result
    catch
        Class:Reason:Stacktrace ->
            ExceptionDuration = erlang:system_time(microsecond) - StartTime,

            %% Emit exception event
            telemetry:execute(EventPrefix ++ [exception], #{
                duration => ExceptionDuration
            }, Metadata#{
                kind => Class,
                reason => Reason,
                stacktrace => Stacktrace
            }),

            erlang:raise(Class, Reason, Stacktrace)
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
attach_events(HandlerIdPrefix, Events, HandlerFun) ->
    lists:foreach(fun(Event) ->
        HandlerId = make_handler_id(HandlerIdPrefix, Event),
        case telemetry:attach(HandlerId, Event, HandlerFun, #{}) of
            ok -> ok;
            {error, already_exists} -> ok
        end
    end, Events),
    ok.

%% @private
make_handler_id(Prefix, Event) ->
    EventName = lists:flatten(io_lib:format("~p", [Event])),
    list_to_atom(atom_to_list(Prefix) ++ "_" ++ EventName).
