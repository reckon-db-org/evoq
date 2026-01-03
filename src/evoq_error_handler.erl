%% @doc Error handler behavior for evoq.
%%
%% Defines how to handle errors during event processing.
%% Supports multiple strategies: retry, skip, stop, dead_letter.
%%
%% == Error Actions ==
%%
%% - retry: Retry immediately
%% - {retry, DelayMs}: Retry after delay
%% - skip: Skip this event and continue
%% - stop: Stop the handler
%% - {dead_letter, Reason}: Send to dead letter queue
%%
%% == Default Behavior ==
%%
%% Without implementing on_error/4, handlers use exponential backoff
%% with max 5 retries, then dead letter.
%%
%% @author rgfaber
-module(evoq_error_handler).

-include("evoq.hrl").
-include("evoq_telemetry.hrl").

%% Types
-type error_action() ::
    retry |
    {retry, DelayMs :: pos_integer()} |
    skip |
    stop |
    {dead_letter, Reason :: term()}.

-export_type([error_action/0]).

%% Callback for custom error handling
-callback on_error(Error :: term(), Event :: map(),
                   FailureContext :: #evoq_failure_context{}, State :: term()) ->
    error_action().

%% Optional callbacks with defaults
-callback max_retries() -> pos_integer().
-callback backoff_ms(AttemptNumber :: pos_integer()) -> pos_integer().

-optional_callbacks([on_error/4, max_retries/0, backoff_ms/1]).

%% API
-export([handle_error/5]).
-export([default_action/2]).
-export([should_retry/2]).

-define(DEFAULT_MAX_RETRIES, 5).
-define(DEFAULT_BASE_BACKOFF, 100).
-define(DEFAULT_MAX_BACKOFF, 30000).

%%====================================================================
%% API
%%====================================================================

%% @doc Handle an error using the handler's error strategy.
-spec handle_error(atom(), term(), map(), #evoq_failure_context{}, term()) -> error_action().
handle_error(HandlerModule, Error, Event, FailureContext, HandlerState) ->
    %% Check if handler implements on_error/4
    case erlang:function_exported(HandlerModule, on_error, 4) of
        true ->
            Action = HandlerModule:on_error(Error, Event, FailureContext, HandlerState),
            emit_telemetry(Action, HandlerModule, FailureContext),
            Action;
        false ->
            %% Use default behavior
            Action = default_action(HandlerModule, FailureContext),
            emit_telemetry(Action, HandlerModule, FailureContext),
            Action
    end.

%% @doc Get the default error action based on retry count.
-spec default_action(atom(), #evoq_failure_context{}) -> {dead_letter, max_retries_exceeded} | {retry, pos_integer()}.
default_action(HandlerModule, #evoq_failure_context{attempt_number = Attempt}) ->
    MaxRetries = get_max_retries(HandlerModule),

    case Attempt > MaxRetries of
        true ->
            %% Max retries exceeded - dead letter
            {dead_letter, max_retries_exceeded};
        false ->
            %% Calculate backoff delay
            Delay = get_backoff_ms(HandlerModule, Attempt),
            {retry, Delay}
    end.

%% @doc Check if we should retry based on the failure context.
-spec should_retry(atom(), #evoq_failure_context{}) -> boolean().
should_retry(HandlerModule, #evoq_failure_context{attempt_number = Attempt}) ->
    MaxRetries = get_max_retries(HandlerModule),
    Attempt =< MaxRetries.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
get_max_retries(HandlerModule) ->
    case erlang:function_exported(HandlerModule, max_retries, 0) of
        true -> HandlerModule:max_retries();
        false -> ?DEFAULT_MAX_RETRIES
    end.

%% @private
get_backoff_ms(HandlerModule, Attempt) ->
    case erlang:function_exported(HandlerModule, backoff_ms, 1) of
        true ->
            HandlerModule:backoff_ms(Attempt);
        false ->
            %% Default exponential backoff with jitter
            evoq_retry_strategy:next_delay(
                {exponential_jitter, ?DEFAULT_BASE_BACKOFF, ?DEFAULT_MAX_BACKOFF},
                Attempt
            )
    end.

%% @private
emit_telemetry(Action, HandlerModule, FailureContext) ->
    #evoq_failure_context{
        attempt_number = Attempt,
        error = Error
    } = FailureContext,

    case Action of
        retry ->
            telemetry:execute(?TELEMETRY_HANDLER_RETRY, #{
                attempt => Attempt
            }, #{
                handler => HandlerModule,
                action => retry,
                delay => 0
            });
        {retry, Delay} ->
            telemetry:execute(?TELEMETRY_HANDLER_RETRY, #{
                attempt => Attempt,
                delay => Delay
            }, #{
                handler => HandlerModule,
                action => retry
            });
        skip ->
            telemetry:execute(?TELEMETRY_HANDLER_DEAD_LETTER, #{}, #{
                handler => HandlerModule,
                action => skip,
                error => Error
            });
        stop ->
            telemetry:execute(?TELEMETRY_HANDLER_DEAD_LETTER, #{}, #{
                handler => HandlerModule,
                action => stop,
                error => Error
            });
        {dead_letter, Reason} ->
            telemetry:execute(?TELEMETRY_HANDLER_DEAD_LETTER, #{}, #{
                handler => HandlerModule,
                action => dead_letter,
                error => Error,
                reason => Reason
            })
    end.
