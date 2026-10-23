%% @doc A projection that fails twice and reports what on_error/4 reads as
%% the failure duration (evoq#12). The projection builds its own failure
%% context, as the event handler does.
-module(evoq_duration_probe_projection).
-behaviour(evoq_projection).

-export([interested_in/0, init/1, project/4, on_error/4]).

interested_in() -> [<<"duration_probe_v1">>].

init(#{sink := Sink}) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, Sink, RM}.

project(_Event, _Metadata, _Sink, _RM) ->
    {error, deliberately_rejected}.

on_error(_Error, _Event, FailureContext, Sink) ->
    evoq_duration_probe_script:report(Sink, FailureContext).
