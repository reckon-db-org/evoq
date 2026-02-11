%% @doc Unit tests for evoq_aggregate behavior.
%%
%% Tests aggregate lifecycle, TTL, and passivation behavior.
%%
%% @author rgfaber
-module(evoq_aggregate_tests).

-compile({no_auto_import, [apply/2]}).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

%%====================================================================
%% Test Fixtures
%%====================================================================

%% Sample aggregate for testing
-behaviour(evoq_aggregate).
-export([init/1, execute/2, apply/2, snapshot/1, from_snapshot/1]).

init(_AggregateId) ->
    {ok, #{counter => 0, status => active}}.

execute(#{status := closed}, _Command) ->
    {error, aggregate_closed};
execute(_State, #{command_type := increment, amount := Amount}) ->
    {ok, [#{event_type => <<"CounterIncremented">>, data => #{amount => Amount}}]};
execute(_State, #{command_type := decrement, amount := Amount}) ->
    {ok, [#{event_type => <<"CounterDecremented">>, data => #{amount => Amount}}]};
execute(_State, #{command_type := close}) ->
    {ok, [#{event_type => <<"CounterClosed">>, data => #{}}]};
execute(_State, _Command) ->
    {error, unknown_command}.

apply(#{counter := Counter} = State, #{event_type := <<"CounterIncremented">>, data := #{amount := Amount}}) ->
    State#{counter => Counter + Amount};
apply(#{counter := Counter} = State, #{event_type := <<"CounterDecremented">>, data := #{amount := Amount}}) ->
    State#{counter => Counter - Amount};
apply(State, #{event_type := <<"CounterClosed">>}) ->
    State#{status => closed};
apply(State, _Event) ->
    State.

snapshot(State) ->
    State.

from_snapshot(SnapshotData) ->
    SnapshotData.

%%====================================================================
%% Test Setup
%%====================================================================

setup() ->
    %% Initialize state for testing
    {ok, InitState} = init(<<"test-123">>),
    InitState.

%%====================================================================
%% Unit Tests
%%====================================================================

aggregate_init_test() ->
    {ok, State} = init(<<"agg-001">>),
    ?assertEqual(0, maps:get(counter, State)),
    ?assertEqual(active, maps:get(status, State)).

aggregate_execute_increment_test() ->
    State = setup(),
    Command = #{command_type => increment, amount => 5},
    {ok, Events} = execute(State, Command),
    ?assertEqual(1, length(Events)),
    [Event] = Events,
    ?assertEqual(<<"CounterIncremented">>, maps:get(event_type, Event)),
    ?assertEqual(#{amount => 5}, maps:get(data, Event)).

aggregate_execute_decrement_test() ->
    State = setup(),
    Command = #{command_type => decrement, amount => 3},
    {ok, Events} = execute(State, Command),
    ?assertEqual(1, length(Events)),
    [Event] = Events,
    ?assertEqual(<<"CounterDecremented">>, maps:get(event_type, Event)).

aggregate_execute_unknown_command_test() ->
    State = setup(),
    Command = #{command_type => unknown},
    Result = execute(State, Command),
    ?assertEqual({error, unknown_command}, Result).

aggregate_execute_closed_test() ->
    State = #{counter => 10, status => closed},
    Command = #{command_type => increment, amount => 1},
    Result = execute(State, Command),
    ?assertEqual({error, aggregate_closed}, Result).

aggregate_apply_increment_test() ->
    State = #{counter => 5, status => active},
    Event = #{event_type => <<"CounterIncremented">>, data => #{amount => 3}},
    NewState = apply(State, Event),
    ?assertEqual(8, maps:get(counter, NewState)).

aggregate_apply_decrement_test() ->
    State = #{counter => 10, status => active},
    Event = #{event_type => <<"CounterDecremented">>, data => #{amount => 4}},
    NewState = apply(State, Event),
    ?assertEqual(6, maps:get(counter, NewState)).

aggregate_apply_close_test() ->
    State = #{counter => 10, status => active},
    Event = #{event_type => <<"CounterClosed">>, data => #{}},
    NewState = apply(State, Event),
    ?assertEqual(closed, maps:get(status, NewState)).

aggregate_snapshot_roundtrip_test() ->
    OriginalState = #{counter => 42, status => active},
    SnapshotData = snapshot(OriginalState),
    RestoredState = from_snapshot(SnapshotData),
    ?assertEqual(OriginalState, RestoredState).

aggregate_event_chain_test() ->
    %% Test applying multiple events in sequence
    State0 = #{counter => 0, status => active},
    Events = [
        #{event_type => <<"CounterIncremented">>, data => #{amount => 10}},
        #{event_type => <<"CounterDecremented">>, data => #{amount => 3}},
        #{event_type => <<"CounterIncremented">>, data => #{amount => 5}}
    ],
    FinalState = lists:foldl(fun(Event, AccState) ->
        apply(AccState, Event)
    end, State0, Events),
    ?assertEqual(12, maps:get(counter, FinalState)).

%%====================================================================
%% Execution Context Tests
%%====================================================================

execution_context_new_test() ->
    Command = #evoq_command{
        command_id = <<"cmd-001">>,
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-001">>,
        causation_id = <<"cause-001">>,
        correlation_id = <<"corr-001">>,
        metadata = #{user_id => <<"user-123">>}
    },
    Context = evoq_execution_context:new(Command),
    ?assertEqual(<<"cmd-001">>, Context#evoq_execution_context.command_id),
    ?assertEqual(<<"agg-001">>, Context#evoq_execution_context.aggregate_id),
    ?assertEqual(10, Context#evoq_execution_context.retry_attempts).

execution_context_retry_test() ->
    Command = #evoq_command{
        command_id = <<"cmd-002">>,
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-002">>
    },
    Context = evoq_execution_context:new(Command, #{retry_attempts => 3}),
    ?assertEqual(3, Context#evoq_execution_context.retry_attempts),

    {ok, Context2} = evoq_execution_context:retry(Context),
    ?assertEqual(2, Context2#evoq_execution_context.retry_attempts),

    {ok, Context3} = evoq_execution_context:retry(Context2),
    ?assertEqual(1, Context3#evoq_execution_context.retry_attempts),

    {ok, Context4} = evoq_execution_context:retry(Context3),
    ?assertEqual(0, Context4#evoq_execution_context.retry_attempts),

    %% Should fail when retries exhausted
    ?assertEqual({error, too_many_attempts}, evoq_execution_context:retry(Context4)).

execution_context_can_retry_test() ->
    Command = #evoq_command{
        command_id = <<"cmd-003">>,
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-003">>
    },
    Context = evoq_execution_context:new(Command, #{retry_attempts => 1}),
    ?assertEqual(true, evoq_execution_context:can_retry(Context)),

    {ok, Context2} = evoq_execution_context:retry(Context),
    ?assertEqual(false, evoq_execution_context:can_retry(Context2)).

execution_context_metadata_test() ->
    Command = #evoq_command{
        command_id = <<"cmd-004">>,
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-004">>,
        metadata = #{key1 => value1}
    },
    Context = evoq_execution_context:new(Command),
    ?assertEqual(value1, evoq_execution_context:get(key1, Context)),
    ?assertEqual(undefined, evoq_execution_context:get(key2, Context)),

    Context2 = evoq_execution_context:put(key2, value2, Context),
    ?assertEqual(value2, evoq_execution_context:get(key2, Context2)).

%%====================================================================
%% Command Tests
%%====================================================================

command_new_auto_generates_id_test() ->
    Cmd = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    ?assertNotEqual(undefined, Cmd#evoq_command.command_id),
    ?assert(is_binary(Cmd#evoq_command.command_id)).

command_new_auto_generates_correlation_id_test() ->
    Cmd = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    ?assertNotEqual(undefined, Cmd#evoq_command.correlation_id),
    ?assert(is_binary(Cmd#evoq_command.correlation_id)).

command_new_unique_ids_test() ->
    Cmd1 = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    Cmd2 = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    ?assertNotEqual(Cmd1#evoq_command.command_id, Cmd2#evoq_command.command_id).

command_idempotency_key_default_undefined_test() ->
    Cmd = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    ?assertEqual(undefined, evoq_command:get_idempotency_key(Cmd)).

command_set_idempotency_key_test() ->
    Cmd0 = evoq_command:new(increment, ?MODULE, <<"agg-1">>, #{amount => 1}),
    Cmd = evoq_command:set_idempotency_key(<<"form-submit-123">>, Cmd0),
    ?assertEqual(<<"form-submit-123">>, evoq_command:get_idempotency_key(Cmd)).

command_ensure_id_generates_when_undefined_test() ->
    Cmd0 = #evoq_command{
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-1">>,
        payload = #{amount => 1}
    },
    ?assertEqual(undefined, Cmd0#evoq_command.command_id),
    Cmd = evoq_command:ensure_id(Cmd0),
    ?assertNotEqual(undefined, Cmd#evoq_command.command_id),
    ?assert(is_binary(Cmd#evoq_command.command_id)).

command_ensure_id_preserves_existing_test() ->
    Cmd0 = #evoq_command{
        command_id = <<"my-custom-id">>,
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-1">>
    },
    Cmd = evoq_command:ensure_id(Cmd0),
    ?assertEqual(<<"my-custom-id">>, Cmd#evoq_command.command_id).

command_validate_allows_undefined_command_id_test() ->
    Cmd = #evoq_command{
        command_type = increment,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-1">>
    },
    ?assertEqual(ok, evoq_command:validate(Cmd)).

command_validate_rejects_missing_command_type_test() ->
    Cmd = #evoq_command{
        command_id = <<"cmd-1">>,
        aggregate_type = ?MODULE,
        aggregate_id = <<"agg-1">>
    },
    ?assertEqual({error, missing_command_type}, evoq_command:validate(Cmd)).

command_validate_rejects_missing_aggregate_type_test() ->
    Cmd = #evoq_command{
        command_id = <<"cmd-1">>,
        command_type = increment,
        aggregate_id = <<"agg-1">>
    },
    ?assertEqual({error, missing_aggregate_type}, evoq_command:validate(Cmd)).

command_validate_rejects_missing_aggregate_id_test() ->
    Cmd = #evoq_command{
        command_id = <<"cmd-1">>,
        command_type = increment,
        aggregate_type = ?MODULE
    },
    ?assertEqual({error, missing_aggregate_id}, evoq_command:validate(Cmd)).

%%====================================================================
%% Lifespan Tests
%%====================================================================

lifespan_default_after_event_test() ->
    Timeout = evoq_aggregate_lifespan_default:after_event(#{}),
    %% Default is 30 minutes
    ?assertEqual(1800000, Timeout).

lifespan_default_after_command_test() ->
    Timeout = evoq_aggregate_lifespan_default:after_command(#{}),
    ?assertEqual(1800000, Timeout).

lifespan_default_after_error_test() ->
    Timeout = evoq_aggregate_lifespan_default:after_error(some_error),
    %% Error timeout is 5 minutes
    ?assertEqual(300000, Timeout).

lifespan_default_on_timeout_test() ->
    Result = evoq_aggregate_lifespan_default:on_timeout(#{}),
    ?assertEqual({snapshot, passivate}, Result).

lifespan_default_on_passivate_test() ->
    State = #{counter => 42},
    {ok, SnapshotData} = evoq_aggregate_lifespan_default:on_passivate(State),
    ?assertEqual(State, SnapshotData).
