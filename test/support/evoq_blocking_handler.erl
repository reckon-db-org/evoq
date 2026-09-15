%% @doc Test support handler that blocks inside handle_event/4 until the
%% test explicitly releases it. Used to prove delivery isolation: while
%% this handler is parked mid-event, an unrelated handler must still make
%% progress. Reports lifecycle to a `report_to' pid passed in Config.
-module(evoq_blocking_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"blocking_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"blocking_evt_v1">>, Event, _Metadata, ReportTo) ->
    ReportTo ! {blocking_started, event_id(Event)},
    %% Park here until the test releases us (bounded so a crashed test
    %% can't wedge the node forever).
    receive
        {release, _} -> ok
    after 60000 -> ok
    end,
    ReportTo ! {blocking_done, event_id(Event)},
    {ok, ReportTo};
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

event_id(Event) -> maps:get(event_id, Event, undefined).
