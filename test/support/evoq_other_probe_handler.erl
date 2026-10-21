%% @doc A second event handler, subscribed to the OTHER event a two-event
%% dispatch appends, for the strong consistency tests.
%%
%% It exists to make the multi-event case observable: a dispatch that appends
%% `strong_probe_v1' and `other_probe_v1' reaches two handlers, and each one
%% acknowledges its own event's stream version. Nothing here is slow.
-module(evoq_other_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"other_probe_v1">>].

init(#{sink := Sink}) ->
    {ok, #{sink => Sink}}.

handle_event(EventType, Event, Metadata, #{sink := Sink} = State) ->
    Sink ! {probe_wrote, EventType, Event, Metadata},
    {ok, State}.
