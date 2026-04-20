%% @doc Dispatch-command workload through `evoq_dispatcher:dispatch/2'.
%%
%% Measures end-to-end cost of evoq's full dispatch pipeline:
%% command → middleware → aggregate lookup → execute → persist
%% → after_dispatch → idempotency cache.
%%
%% The aggregate surface used here is the minimal `bench_agg' module
%% in the same slice directory.
-module(dispatch_command).

-behaviour(reckon_bench_slice).

-export([describe/0, setup/1, run/2, teardown/2]).

-include_lib("evoq/include/evoq.hrl").

-define(AGG_PREFIX, <<"bench.dispatch_command.">>).

describe() ->
    #{
        question => <<
            "End-to-end dispatch latency through evoq: command-in -> "
            "event-stored, with the full middleware pipeline."
        >>,
        units => #{
            throughput_ops_sec => <<"dispatches/sec sustained">>,
            latency_ns_p99     => <<"p99 dispatch call latency">>
        },
        behaviours_exercised =>
            [command, handler, aggregate, event, store_adapter],
        metrics => [
            throughput_ops_sec,
            latency_ns_p50,
            latency_ns_p90,
            latency_ns_p95,
            latency_ns_p99,
            latency_ns_p99_9,
            latency_ns_p99_99,
            cpu_ms_per_op,
            memory_high_water_mb,
            disk_bytes_per_op
        ]
    }.

setup(Scenario) ->
    AggregateId = fresh_aggregate_id(),
    Size        = maps:get(event_size_bytes, Scenario, 256),
    Payload     = binary:copy(<<$x>>, Size),
    #{
        aggregate_type => bench_agg,
        aggregate_id   => AggregateId,
        data_bytes     => Payload,
        next_seq       => 0
    }.

run(#{aggregate_type := AggType,
      aggregate_id   := AggId,
      data_bytes     := Payload,
      next_seq       := Seq} = State, _Scenario) ->
    %% Pass the 256-byte payload through the command so the resulting
    %% event has comparable size to the bare-storage slice. Without
    %% this, the bench measures dispatch cost on empty events — which
    %% is not what a real CQRS workload looks like.
    CmdPayload = #{seq => Seq, payload => Payload},
    Command = evoq_command:new(bench_append, AggType, AggId, CmdPayload),
    Opts = #{
        store_id         => bench_store,
        expected_version => -2  %% ANY_VERSION
    },
    {ok, _Version, _Events} = evoq_dispatcher:dispatch(Command, Opts),
    {ok, State#{next_seq => Seq + 1}}.

teardown(_State, _Scenario) ->
    ok.

fresh_aggregate_id() ->
    <<?AGG_PREFIX/binary,
      (integer_to_binary(erlang:unique_integer([positive])))/binary>>.
