%% @doc A process manager with no handle_info/2: a message sent to its
%% instance must be reported (naming the module and the message) rather
%% than dropped in silence, and the instance must survive it.
-module(evoq_info_probe_deaf_pm).
-behaviour(evoq_process_manager).

-export([interested_in/0, correlate/2, handle/3, apply/2]).

interested_in() -> [].
correlate(_Event, _Metadata) -> false.
handle(State, _Event, _Metadata) -> {ok, State}.
apply(State, _Event) -> State.
