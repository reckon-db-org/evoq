%% @doc Retry strategies for error handling.
%%
%% Provides various backoff strategies:
%% - immediate: No delay between retries
%% - fixed: Constant delay
%% - exponential: Doubles each time up to max
%% - exponential_jitter: Exponential with random jitter
%%
%% == Usage ==
%%
%% ```
%% %% Get delay for attempt 3 with exponential backoff
%% Delay = evoq_retry_strategy:next_delay({exponential, 100, 30000}, 3).
%% %% Returns approximately 400ms (100 * 2^2)
%% '''
%%
%% @author rgfaber
-module(evoq_retry_strategy).

%% Types
-type strategy() ::
    immediate |
    {fixed, DelayMs :: pos_integer()} |
    {exponential, BaseMs :: pos_integer(), MaxMs :: pos_integer()} |
    {exponential_jitter, BaseMs :: pos_integer(), MaxMs :: pos_integer()}.

-export_type([strategy/0]).

%% API
-export([next_delay/2]).
-export([immediate/0, fixed/1, exponential/2, exponential_jitter/2]).

%%====================================================================
%% API - Strategy Constructors
%%====================================================================

%% @doc Create an immediate retry strategy.
-spec immediate() -> immediate.
immediate() -> immediate.

%% @doc Create a fixed delay retry strategy.
-spec fixed(pos_integer()) -> {fixed, pos_integer()}.
fixed(DelayMs) -> {fixed, DelayMs}.

%% @doc Create an exponential backoff strategy.
-spec exponential(pos_integer(), pos_integer()) -> {exponential, pos_integer(), pos_integer()}.
exponential(BaseMs, MaxMs) -> {exponential, BaseMs, MaxMs}.

%% @doc Create an exponential backoff with jitter strategy.
-spec exponential_jitter(pos_integer(), pos_integer()) -> {exponential_jitter, pos_integer(), pos_integer()}.
exponential_jitter(BaseMs, MaxMs) -> {exponential_jitter, BaseMs, MaxMs}.

%%====================================================================
%% API - Delay Calculation
%%====================================================================

%% @doc Calculate the next delay for a given attempt.
-spec next_delay(strategy(), pos_integer()) -> pos_integer().
next_delay(immediate, _Attempt) ->
    0;

next_delay({fixed, DelayMs}, _Attempt) ->
    DelayMs;

next_delay({exponential, BaseMs, MaxMs}, Attempt) ->
    %% Delay = BaseMs * 2^(Attempt-1), capped at MaxMs
    Multiplier = math:pow(2, Attempt - 1),
    Delay = round(BaseMs * Multiplier),
    min(Delay, MaxMs);

next_delay({exponential_jitter, BaseMs, MaxMs}, Attempt) ->
    %% Exponential with random jitter (0.5 to 1.5 of calculated delay)
    BaseDelay = next_delay({exponential, BaseMs, MaxMs}, Attempt),

    %% Add jitter: multiply by random factor between 0.5 and 1.5
    JitterFactor = 0.5 + rand:uniform(),  %% 0.5 to 1.5
    JitteredDelay = round(BaseDelay * JitterFactor),

    min(JitteredDelay, MaxMs).
