%% @doc An event handler that DISPATCHES from inside `handle_event/4', for
%% the strong consistency tests.
%%
%% It subscribes to the very event type its own command appends, which is the
%% shape of a cascade: the process that would have to acknowledge the new
%% event is the process waiting for it. It cascades once (the second event it
%% receives, its own, is simply acknowledged) and reports the cascade's
%% dispatch result and how long it took.
-module(evoq_cascading_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4]).

interested_in() -> [<<"strong_probe_v1">>].

init(#{sink := Sink}) ->
    {ok, #{sink => Sink, cascades => 0}}.

handle_event(<<"strong_probe_v1">>, _Event, _Metadata, #{sink := Sink, cascades := 0} = State) ->
    Started = erlang:monotonic_time(millisecond),
    Result = evoq_command_router:dispatch(
               evoq_command:new(cascade_probe, evoq_strong_probe_aggregate,
                                <<"stream-cascade">>,
                                #{command_type => <<"emit_cascade_probe">>}),
               #{store_id => test_store, consistency => strong}),
    Sink ! {cascade_result, Result, erlang:monotonic_time(millisecond) - Started},
    {ok, State#{cascades := 1}};
handle_event(_EventType, _Event, _Metadata, State) ->
    {ok, State}.
