%% @doc Failure context for tracking retry state.
%%
%% Maintains state across retry attempts for event handlers.
%% Used to implement sophisticated retry strategies with
%% exponential backoff, jitter, and dead letter handling.
%%
%% @author rgfaber
-module(evoq_failure_context).

-include("evoq.hrl").

%% API
-export([new/3]).
-export([increment/1]).
-export([get_attempt/1, get_error/1, get_event/1]).
-export([get_handler/1, get_duration/1]).
-export([with_stacktrace/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new failure context.
-spec new(atom(), map(), term()) -> #evoq_failure_context{}.
new(HandlerModule, Event, Error) ->
    Now = erlang:system_time(millisecond),
    #evoq_failure_context{
        handler_module = HandlerModule,
        event = Event,
        error = Error,
        attempt_number = 1,
        first_failure_at = Now,
        last_failure_at = Now,
        stacktrace = []
    }.

%% @doc Increment the attempt counter and update timestamp.
-spec increment(#evoq_failure_context{}) -> #evoq_failure_context{}.
increment(#evoq_failure_context{attempt_number = N} = Context) ->
    Context#evoq_failure_context{
        attempt_number = N + 1,
        last_failure_at = erlang:system_time(millisecond)
    }.

%% @doc Get the current attempt number.
-spec get_attempt(#evoq_failure_context{}) -> pos_integer().
get_attempt(#evoq_failure_context{attempt_number = N}) -> N.

%% @doc Get the error that caused the failure.
-spec get_error(#evoq_failure_context{}) -> term().
get_error(#evoq_failure_context{error = Error}) -> Error.

%% @doc Get the event that failed.
-spec get_event(#evoq_failure_context{}) -> map().
get_event(#evoq_failure_context{event = Event}) -> Event.

%% @doc Get the handler module.
-spec get_handler(#evoq_failure_context{}) -> atom().
get_handler(#evoq_failure_context{handler_module = Handler}) -> Handler.

%% @doc Get the duration since first failure.
-spec get_duration(#evoq_failure_context{}) -> non_neg_integer().
get_duration(#evoq_failure_context{first_failure_at = First, last_failure_at = Last}) ->
    Last - First.

%% @doc Add stacktrace to the context.
-spec with_stacktrace(list(), #evoq_failure_context{}) -> #evoq_failure_context{}.
with_stacktrace(Stacktrace, Context) ->
    Context#evoq_failure_context{stacktrace = Stacktrace}.
