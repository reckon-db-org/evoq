%% @doc Test support checkpointed handler. Reports every event id it
%% consumes, in order, so a test can assert catch-up order, resume after a
%% restart, and that a live wakeup delivers new events without skipping.
-module(evoq_ordered_consumer).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"seq_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"seq_evt_v1">>, Event, _Metadata, ReportTo) ->
    ReportTo ! {consumed, maps:get(event_id, Event, undefined)},
    {ok, ReportTo};
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.
