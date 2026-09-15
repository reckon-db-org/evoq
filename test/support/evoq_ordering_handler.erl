%% @doc Test support handler that reports every event it completes, in the
%% order it completes them, so a test can assert per-handler order across a
%% retry. The event tagged <<"a">> fails once (short backoff) then
%% succeeds; every event succeeds exactly once. Reports {order_handled, Id}
%% on each success.
-module(evoq_ordering_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

-define(RETRY_DELAY_MS, 50).

interested_in() -> [<<"order_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"order_evt_v1">>, Event, _Metadata, ReportTo) ->
    Id = maps:get(event_id, Event, undefined),
    %% Retries run in this same process, so the process dictionary is a
    %% reliable per-event attempt counter.
    N = attempt_or_zero(get({attempt, Id})) + 1,
    put({attempt, Id}, N),
    decide(Id, N, ReportTo);
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

%% <<"a">> fails on its first attempt only; then it (and every other
%% event) succeeds exactly once.
decide(<<"a">>, 1, _ReportTo) ->
    {error, transient};
decide(Id, _N, ReportTo) ->
    ReportTo ! {order_handled, Id},
    {ok, ReportTo}.

on_error(_Error, _Event, _FailureContext, _State) ->
    {retry, ?RETRY_DELAY_MS}.

attempt_or_zero(undefined) -> 0;
attempt_or_zero(N) -> N.
