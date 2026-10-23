%% @doc A handler that fails twice and reports what on_error/4 reads as the
%% failure duration (evoq#12).
%%
%% The context it is handed is built by the event handler, not by
%% evoq_failure_context:new/3, so this is the path a real backoff policy
%% sees.
-module(evoq_duration_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

interested_in() -> [<<"duration_probe_v1">>].

init(#{sink := Sink}) ->
    {ok, Sink}.

handle_event(_EventType, _Event, _Metadata, _Sink) ->
    {error, deliberately_rejected}.

on_error(_Error, _Event, FailureContext, Sink) ->
    evoq_duration_probe_script:report(Sink, FailureContext).
