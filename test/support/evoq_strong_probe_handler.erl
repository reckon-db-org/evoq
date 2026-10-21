%% @doc An event handler that takes a known time to write and reports each
%% write to a sink pid, for the strong consistency tests.
%%
%% Nothing is handed to it from outside: the sleep and the sink come from
%% `init/1''s config, so a test can make the write slow enough to be seen and
%% can prove the write happened before the dispatch answered.
-module(evoq_strong_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"strong_probe_v1">>].

init(#{sink := Sink} = Config) ->
    {ok, #{sink => Sink, sleep => maps:get(sleep, Config, 0)}}.

handle_event(EventType, Event, Metadata, #{sink := Sink, sleep := Sleep} = State) ->
    timer:sleep(Sleep),
    Sink ! {probe_wrote, EventType, Event, Metadata},
    {ok, State}.
