%% @doc Test support handler whose first attempt at an event raises. Used
%% to prove that a throwing callback does not take down the handler
%% process (and with it the queued events behind the failed one): the
%% raise must be converted to the error path, so on_error decides what
%% happens. Here on_error/4 skips, so the failed event is dropped and the
%% queue keeps moving. Reports each success to `report_to'.
-module(evoq_raising_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

interested_in() -> [<<"raise_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"raise_evt_v1">>, Event, _Metadata, ReportTo) ->
    handle_by_id(maps:get(event_id, Event, undefined), ReportTo);
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

%% The event tagged <<"boom">> raises; everything else succeeds.
handle_by_id(<<"boom">>, _ReportTo) ->
    error(deliberate_crash);
handle_by_id(Id, ReportTo) ->
    ReportTo ! {raise_handled, Id},
    {ok, ReportTo}.

on_error(_Error, _Event, _FailureContext, _State) ->
    skip.
