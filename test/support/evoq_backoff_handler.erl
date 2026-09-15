%% @doc Test support handler whose first attempt at an event fails and
%% whose on_error/4 asks for a delayed retry. Used to prove that a
%% handler serving out its backoff does not sleep in — or otherwise
%% block — any shared process. Reports each attempt to `report_to'.
-module(evoq_backoff_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

-include("evoq.hrl").

%% Delay long enough that, if it were served in a shared process, an
%% unrelated handler would visibly miss its own tight deadline.
-define(RETRY_DELAY_MS, 3000).

interested_in() -> [<<"backoff_evt_v1">>].

init(Config) ->
    {ok, maps:get(report_to, Config)}.

handle_event(<<"backoff_evt_v1">>, Event, _Metadata, ReportTo) ->
    Id = event_id(Event),
    %% Retries run in this same handler process, so the process
    %% dictionary is a reliable per-event attempt counter regardless of
    %% how handler_state is threaded across the error path.
    N = get_attempt(Id) + 1,
    put_attempt(Id, N),
    ReportTo ! {backoff_attempt, Id, N},
    decide(N, ReportTo, Id);
handle_event(_Other, _Event, _Metadata, ReportTo) ->
    {ok, ReportTo}.

%% First attempt fails (triggering the delayed retry); the second
%% succeeds, so the test can also assert the event is not lost.
decide(1, _ReportTo, _Id) ->
    {error, transient};
decide(_N, ReportTo, Id) ->
    ReportTo ! {backoff_succeeded, Id},
    {ok, ReportTo}.

get_attempt(Id) ->
    attempt_or_zero(get({attempt, Id})).

attempt_or_zero(undefined) -> 0;
attempt_or_zero(N) -> N.

put_attempt(Id, N) ->
    put({attempt, Id}, N),
    ok.

on_error(_Error, _Event, _FailureContext, _State) ->
    {retry, ?RETRY_DELAY_MS}.

event_id(Event) -> maps:get(event_id, Event, undefined).
