%% @doc Three ways of handling one event type, for the delivery isolation
%% tests (evoq#30). Config names the role and the test process to tell.
%%
%% - blocker: holds event 1 for ?BLOCK_MS, as a slow write does.
%% - retrier: fails event 1 and asks for {retry, 500} once, then skips it.
%% - plain: handles everything at once.
-module(evoq_isolation_probe_handler).
-behaviour(evoq_event_handler).

-export([interested_in/0, init/1, handle_event/4, on_error/4]).
-export([block_ms/0, retry_ms/0]).

block_ms() -> 1500.
retry_ms() -> 500.

interested_in() -> [<<"isolation_delivered_v1">>].

init(Config) -> {ok, Config}.

handle_event(_Type, #{data := #{n := N}}, _Metadata, #{role := Role, sink := Sink} = State) ->
    Sink ! {handled, Role, N},
    handled(Role, N, State).

handled(blocker, 1, State) -> timer:sleep(block_ms()), {ok, State};
handled(retrier, 1, _State) -> {error, failing_once};
handled(_Role, _N, State) -> {ok, State}.

on_error(_Error, _Event, FailureContext, _State) ->
    case evoq_failure_context:get_attempt(FailureContext) of
        1 -> {retry, retry_ms()};
        _ -> skip
    end.
