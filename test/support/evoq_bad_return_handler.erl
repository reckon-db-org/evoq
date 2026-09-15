%% @doc Test support handler that returns an unexpected value (a bare
%% `ok', matching neither {ok, _} nor {error, _}) for one designated
%% event. Proves a bad return is taken through the error path rather than
%% raising try_clause and crashing the handler with its queue. on_error/4
%% skips, so the bad event is dropped and the queue keeps moving. Reports
%% each success to `report_to'.
-module(evoq_bad_return_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

interested_in() -> [<<"ret_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"ret_evt_v1">>, Event, _Metadata, ReportTo) ->
    handle_by_id(maps:get(event_id, Event, undefined), ReportTo);
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

%% The event tagged <<"badret">> returns a bare `ok' (a contract
%% violation); everything else returns the proper {ok, State}.
handle_by_id(<<"badret">>, _ReportTo) ->
    ok;
handle_by_id(Id, ReportTo) ->
    ReportTo ! {ret_handled, Id},
    {ok, ReportTo}.

on_error(_Error, _Event, _FailureContext, _State) ->
    skip.
