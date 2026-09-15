%% @doc Test support handler that processes its event immediately and
%% reports it to a `report_to' pid. Its promptness under load is the
%% signal the isolation tests assert on: it must be handled even while an
%% unrelated handler is parked or backing off.
-module(evoq_prompt_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"prompt_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"prompt_evt_v1">>, Event, _Metadata, ReportTo) ->
    ReportTo ! {prompt_handled, event_id(Event)},
    {ok, ReportTo};
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

event_id(Event) -> maps:get(event_id, Event, undefined).
