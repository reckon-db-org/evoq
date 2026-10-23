%% @doc The error policy both duration probes share: retry once after a
%% delay, then skip, telling the test what each attempt read.
-module(evoq_duration_probe_script).

-export([retry_delay/0, report/2]).

retry_delay() -> 30.

report(Sink, FailureContext) ->
    Attempt = evoq_failure_context:get_attempt(FailureContext),
    Sink ! {failure_read, Attempt, evoq_failure_context:get_duration(FailureContext)},
    next(Attempt).

next(1) -> {retry, retry_delay()};
next(_) -> skip.
