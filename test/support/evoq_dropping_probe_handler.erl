%% @doc A handler whose own error policy drops the event, for the strong
%% consistency tests (evoq#23).
%%
%% The write fails and `on_error/4' answers `skip', which is what a handler
%% with a deliberate drop policy does. Nothing is written, so a dispatch
%% waiting for the write must not be told it happened.
-module(evoq_dropping_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).

interested_in() -> [<<"strong_probe_v1">>].

init(_Config) ->
    {ok, #{}}.

handle_event(_EventType, _Event, _Metadata, _State) ->
    {error, deliberately_rejected}.

%% The drop: the handler decided this event is not going to be written.
on_error(_Error, _Event, _FailureContext, _State) ->
    skip.
