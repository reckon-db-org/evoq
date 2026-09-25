%% @doc Test support handler whose bad return carries a secret and whose
%% on_error dead-letters the event. Proves the shape reduction protects the
%% dead-letter path too: neither the error term nor the failure context may
%% carry the returned payload.
-module(evoq_leaky_deadletter_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

interested_in() -> [<<"dl_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"dl_evt_v1">>, _Event, _Metadata, _ReportTo) ->
    {oops, <<"secret-payload-xyz">>};
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

on_error(_Error, _Event, _FailureContext, _State) ->
    {dead_letter, quarantined}.
