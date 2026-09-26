%% @doc A process manager on two types no event handler consumes, correlating
%% on the order id and keeping per-order state: it records, for every event
%% it handles, the state it had for that order at that moment.
-module(evoq_order_probe_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, init/1, handle/3, apply/2]).

interested_in() -> [<<"pm_order_placed_v1">>, <<"pm_order_paid_v1">>].

%% {continue, Id} for both types: every delivery looks its instance up (a
%% {start, _} always makes a new one), which is what exposes two process
%% managers reaching each other's instance.
correlate(#{data := #{order := Id}}, _Meta) ->
    {continue, Id}.

init(OrderId) -> {ok, #{order => OrderId, seen => []}}.

handle(State, #{event_type := Type, data := #{order := Id}}, Metadata) ->
    evoq_replay_probe:record(order_pm, {Type, Id, State}, Metadata),
    {ok, State}.

apply(#{seen := Seen} = State, #{event_type := Type}) ->
    State#{seen => Seen ++ [Type]}.
