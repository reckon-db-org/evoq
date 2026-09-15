%% @doc Test support handler whose bad return carries a secret payload.
%% Proves that the {bad_return, ...} error term keeps only the return's
%% shape, never the whole return value, so event data or handler state a
%% return can carry does not reach on_error, a dead letter, or a log. Its
%% on_error/4 reports the error term it was handed to `report_to'.
-module(evoq_leaky_return_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

interested_in() -> [<<"leak_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"leak_evt_v1">>, _Event, _Metadata, _ReportTo) ->
    %% A contract violation whose value embeds a secret.
    {oops, <<"secret-payload-xyz">>};
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

on_error(Error, _Event, _FailureContext, ReportTo) ->
    ReportTo ! {captured_error, Error},
    skip.
