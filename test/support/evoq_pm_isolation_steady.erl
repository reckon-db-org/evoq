%% @doc A process manager that handles every event it is given and tells the
%% isolation suite (evoq#9). It shares its event types with
%% evoq_pm_isolation_crashing, which sorts before it, so a router that dies
%% on the crasher never reaches it.
-module(evoq_pm_isolation_steady).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2]).

interested_in() -> evoq_pm_isolation_crashing:interested_in().

correlate(_Event, _Metadata) -> {continue, <<"steady">>}.

handle(State, #{data := #{n := N}}, _Metadata) ->
    persistent_term:get({evoq_pm_isolation_SUITE, sink}) ! {steady_handled, N},
    {ok, State}.

apply(State, _Event) -> State.
