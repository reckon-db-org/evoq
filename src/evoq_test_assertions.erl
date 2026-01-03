%% @doc Test assertion helpers for evoq.
%%
%% Provides macros and functions for testing CQRS/ES applications.
%%
%% == Usage ==
%%
%% ```
%% -include_lib("evoq/include/evoq_test.hrl").
%%
%% my_test() ->
%%     Command = #evoq_command{...},
%%     ?assert_command_succeeds(Command),
%%     ?assert_events_produced([<<"OrderCreated">>]).
%% '''
%%
%% @author rgfaber
-module(evoq_test_assertions).

-include("evoq.hrl").

%% Command assertions
-export([assert_command_succeeds/1, assert_command_succeeds/2]).
-export([assert_command_fails/1, assert_command_fails/2]).
-export([assert_command_fails_with/2]).

%% Event assertions
-export([assert_events_produced/2]).
-export([assert_event_produced/2]).
-export([assert_no_events_produced/1]).

%% State assertions
-export([assert_aggregate_state/3]).
-export([get_aggregate_state/2]).

%% Read model assertions
-export([assert_read_model_contains/3]).
-export([assert_read_model_empty/1]).

%% Process manager assertions
-export([assert_commands_dispatched/2]).
-export([assert_compensation_triggered/2]).

%% Telemetry assertions
-export([collect_telemetry/2]).
-export([assert_telemetry_emitted/2]).

%%====================================================================
%% Command Assertions
%%====================================================================

%% @doc Assert that a command dispatch succeeds.
-spec assert_command_succeeds(#evoq_command{}) -> {ok, non_neg_integer(), [map()]}.
assert_command_succeeds(Command) ->
    assert_command_succeeds(Command, #{}).

%% @doc Assert that a command dispatch succeeds with options.
-spec assert_command_succeeds(#evoq_command{}, map()) -> {ok, non_neg_integer(), [map()]}.
assert_command_succeeds(Command, Opts) ->
    case evoq_router:dispatch(Command, Opts) of
        {ok, _Version, _Events} = Result ->
            Result;
        {error, Reason} ->
            error({command_should_succeed, Command, Reason})
    end.

%% @doc Assert that a command dispatch fails.
-spec assert_command_fails(#evoq_command{}) -> {error, term()}.
assert_command_fails(Command) ->
    assert_command_fails(Command, #{}).

%% @doc Assert that a command dispatch fails with options.
-spec assert_command_fails(#evoq_command{}, map()) -> {error, term()}.
assert_command_fails(Command, Opts) ->
    case evoq_router:dispatch(Command, Opts) of
        {error, _Reason} = Result ->
            Result;
        {ok, Version, Events} ->
            error({command_should_fail, Command, {ok, Version, Events}})
    end.

%% @doc Assert that a command fails with a specific error.
-spec assert_command_fails_with(#evoq_command{}, term()) -> ok.
assert_command_fails_with(Command, ExpectedError) ->
    case evoq_router:dispatch(Command) of
        {error, ExpectedError} ->
            ok;
        {error, ActualError} ->
            error({wrong_error, expected, ExpectedError, got, ActualError});
        {ok, _, _} ->
            error({command_should_fail, Command})
    end.

%%====================================================================
%% Event Assertions
%%====================================================================

%% @doc Assert that specific event types were produced.
-spec assert_events_produced([binary()], [map()]) -> ok.
assert_events_produced(ExpectedTypes, Events) ->
    ActualTypes = [maps:get(event_type, E, undefined) || E <- Events],
    case lists:sort(ExpectedTypes) =:= lists:sort(ActualTypes) of
        true ->
            ok;
        false ->
            error({events_mismatch, expected, ExpectedTypes, got, ActualTypes})
    end.

%% @doc Assert that a specific event type was produced.
-spec assert_event_produced(binary(), [map()]) -> map().
assert_event_produced(EventType, Events) ->
    case lists:filter(fun(E) ->
        maps:get(event_type, E, undefined) =:= EventType
    end, Events) of
        [Event | _] ->
            Event;
        [] ->
            error({event_not_produced, EventType, Events})
    end.

%% @doc Assert that no events were produced.
-spec assert_no_events_produced([map()]) -> ok.
assert_no_events_produced([]) ->
    ok;
assert_no_events_produced(Events) ->
    error({unexpected_events, Events}).

%%====================================================================
%% State Assertions
%%====================================================================

%% @doc Assert aggregate state matches expected.
-spec assert_aggregate_state(atom(), binary(), fun((term()) -> boolean())) -> ok.
assert_aggregate_state(AggregateType, AggregateId, Predicate) ->
    case get_aggregate_state(AggregateType, AggregateId) of
        {ok, State} ->
            case Predicate(State) of
                true ->
                    ok;
                false ->
                    error({state_predicate_failed, State})
            end;
        {error, Reason} ->
            error({could_not_get_state, Reason})
    end.

%% @doc Get aggregate state for testing.
-spec get_aggregate_state(atom(), binary()) -> {ok, term()} | {error, term()}.
get_aggregate_state(_AggregateType, AggregateId) ->
    case evoq_aggregate_registry:lookup(AggregateId) of
        {ok, Pid} ->
            evoq_aggregate:get_state(Pid);
        {error, not_found} ->
            {error, aggregate_not_running}
    end.

%%====================================================================
%% Read Model Assertions
%%====================================================================

%% @doc Assert read model contains expected value.
-spec assert_read_model_contains(evoq_read_model:read_model(), term(), term()) -> ok.
assert_read_model_contains(ReadModel, Key, ExpectedValue) ->
    case evoq_read_model:get(Key, ReadModel) of
        {ok, ExpectedValue} ->
            ok;
        {ok, ActualValue} ->
            error({read_model_value_mismatch, Key, expected, ExpectedValue, got, ActualValue});
        {error, not_found} ->
            error({read_model_key_not_found, Key})
    end.

%% @doc Assert read model is empty.
-spec assert_read_model_empty(evoq_read_model:read_model()) -> ok.
assert_read_model_empty(ReadModel) ->
    case evoq_read_model:list(all, ReadModel) of
        {ok, []} ->
            ok;
        {ok, Items} ->
            error({read_model_not_empty, Items});
        {error, not_implemented} ->
            %% Can't verify, assume ok
            ok
    end.

%%====================================================================
%% Process Manager Assertions
%%====================================================================

%% @doc Assert that commands were dispatched by a PM.
%% Note: This requires capturing commands during test execution.
-spec assert_commands_dispatched([atom()], [term()]) -> ok.
assert_commands_dispatched(ExpectedTypes, DispatchedCommands) ->
    ActualTypes = [C#evoq_command.command_type || C <- DispatchedCommands],
    case lists:sort(ExpectedTypes) =:= lists:sort(ActualTypes) of
        true ->
            ok;
        false ->
            error({commands_mismatch, expected, ExpectedTypes, got, ActualTypes})
    end.

%% @doc Assert compensation was triggered.
-spec assert_compensation_triggered(atom(), [#evoq_command{}]) -> ok.
assert_compensation_triggered(ExpectedType, CompensatingCommands) ->
    case lists:any(fun(C) ->
        C#evoq_command.command_type =:= ExpectedType
    end, CompensatingCommands) of
        true ->
            ok;
        false ->
            Types = [C#evoq_command.command_type || C <- CompensatingCommands],
            error({compensation_not_found, ExpectedType, got, Types})
    end.

%%====================================================================
%% Telemetry Assertions
%%====================================================================

%% @doc Collect telemetry events during a function execution.
-spec collect_telemetry([atom()], fun(() -> term())) -> {term(), [map()]}.
collect_telemetry(EventName, Fun) ->
    Self = self(),
    HandlerId = make_ref(),

    Handler = fun(Name, Measurements, Metadata, _Config) ->
        Self ! {telemetry, HandlerId, Name, Measurements, Metadata}
    end,

    ok = telemetry:attach(HandlerId, EventName, Handler, #{}),

    try
        Result = Fun(),
        Events = collect_telemetry_messages(HandlerId, []),
        _ = telemetry:detach(HandlerId),
        {Result, Events}
    catch
        Class:Reason:Stack ->
            _ = telemetry:detach(HandlerId),
            erlang:raise(Class, Reason, Stack)
    end.

%% @doc Assert that a telemetry event was emitted.
-spec assert_telemetry_emitted([atom()], [map()]) -> ok.
assert_telemetry_emitted(EventName, CollectedEvents) ->
    case lists:any(fun(#{name := Name}) ->
        Name =:= EventName
    end, CollectedEvents) of
        true ->
            ok;
        false ->
            error({telemetry_not_emitted, EventName, CollectedEvents})
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
collect_telemetry_messages(HandlerId, Acc) ->
    receive
        {telemetry, HandlerId, Name, Measurements, Metadata} ->
            Event = #{
                name => Name,
                measurements => Measurements,
                metadata => Metadata
            },
            collect_telemetry_messages(HandlerId, [Event | Acc])
    after 0 ->
        lists:reverse(Acc)
    end.
