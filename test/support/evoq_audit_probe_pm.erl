%% @doc A second process manager on pm_order_placed_v1, correlating on the
%% same order id as evoq_order_probe_pm: the two must keep separate
%% instances and separate state for the same id.
-module(evoq_audit_probe_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, init/1, handle/3, apply/2]).

interested_in() -> [<<"pm_order_placed_v1">>].

correlate(#{data := #{order := Id}}, _Meta) -> {continue, Id}.

init(OrderId) -> {ok, #{audit_of => OrderId, count => 0}}.

handle(State, #{data := #{order := Id}}, Metadata) ->
    evoq_replay_probe:record(audit_pm, {Id, State}, Metadata),
    {ok, State}.

apply(#{count := N} = State, _Event) -> State#{count => N + 1}.
