%% @doc Bit flag manipulation for aggregate state management.
%%
%% This module provides functions for working with bitwise flags, which are
%% particularly useful in event-sourced systems where aggregate state can be
%% represented as a set of flags (finite state machine).
%%
%% == Why Use Bit Flags? ==
%%
%% <ul>
%%   <li><b>Memory Efficiency</b>: Store multiple boolean states in a single integer</li>
%%   <li><b>Performance</b>: Bitwise operations are extremely fast</li>
%%   <li><b>Atomic Operations</b>: Update multiple flags in a single operation</li>
%%   <li><b>Event Sourcing</b>: Efficiently represent aggregate state in event streams</li>
%%   <li><b>Database Queries</b>: Use bitwise operators in SQL/NoSQL queries</li>
%% </ul>
%%
%% == Flag Values ==
%%
%% Flags must be powers of 2 to occupy unique bit positions:
%%
%% ```
%% -define(NONE,       0).    % 2#00000000
%% -define(CREATED,    1).    % 2#00000001
%% -define(VALIDATED,  2).    % 2#00000010
%% -define(PROCESSING, 4).    % 2#00000100
%% -define(COMPLETED,  8).    % 2#00001000
%% -define(CANCELLED, 16).    % 2#00010000
%% -define(ARCHIVED,  32).    % 2#00100000
%% '''
%%
%% == Example Usage ==
%%
%% ```
%% %% Start with no flags
%% State0 = 0,
%%
%% %% Set CREATED flag
%% State1 = evoq_bit_flags:set(State0, 1),   % State1 = 1
%%
%% %% Set VALIDATED flag
%% State2 = evoq_bit_flags:set(State1, 2),   % State2 = 3
%%
%% %% Check if CREATED is set
%% true = evoq_bit_flags:has(State2, 1),
%%
%% %% Check if CANCELLED is set
%% false = evoq_bit_flags:has(State2, 16).
%% '''
%%
%% Inspired by C# Flags enum attribute.
%% @end
-module(evoq_bit_flags).

-export([
    %% Core operations
    set/2,
    unset/2,
    set_all/2,
    unset_all/2,

    %% Query operations
    has/2,
    has_not/2,
    has_all/2,
    has_any/2,

    %% Conversion operations
    to_list/2,
    to_string/2,
    to_string/3,
    decompose/1,

    %% Analysis operations
    highest/2,
    lowest/2
]).

-type flags() :: non_neg_integer().
-type flag() :: pos_integer().
-type flag_map() :: #{non_neg_integer() => binary() | string()}.

-export_type([flags/0, flag/0, flag_map/0]).

%% =============================================================================
%% Core Operations
%% =============================================================================

%% @doc Sets a flag in the target state using bitwise OR.
%%
%% Example:
%% ```
%% 100 = evoq_bit_flags:set(36, 64).
%% %% 36 = 2#00100100, 64 = 2#01000000
%% %% Result: 2#01100100 = 100
%% '''
-spec set(flags(), flag()) -> flags().
set(Target, Flag) when is_integer(Target), is_integer(Flag) ->
    Target bor Flag.

%% @doc Unsets a flag in the target state using bitwise AND with NOT.
%%
%% Example:
%% ```
%% 36 = evoq_bit_flags:unset(100, 64).
%% %% 100 = 2#01100100, 64 = 2#01000000
%% %% Result: 2#00100100 = 36
%% '''
-spec unset(flags(), flag()) -> flags().
unset(Target, Flag) when is_integer(Target), is_integer(Flag) ->
    Target band (bnot Flag).

%% @doc Sets multiple flags in the target state.
%%
%% Example:
%% ```
%% 228 = evoq_bit_flags:set_all(36, [64, 128]).
%% '''
-spec set_all(flags(), [flag()]) -> flags().
set_all(Target, Flags) when is_integer(Target), is_list(Flags) ->
    lists:foldl(fun(Flag, Acc) -> Acc bor Flag end, Target, Flags).

%% @doc Unsets multiple flags in the target state.
%%
%% Example:
%% ```
%% 36 = evoq_bit_flags:unset_all(228, [64, 128]).
%% '''
-spec unset_all(flags(), [flag()]) -> flags().
unset_all(Target, Flags) when is_integer(Target), is_list(Flags) ->
    lists:foldl(fun(Flag, Acc) -> Acc band (bnot Flag) end, Target, Flags).

%% =============================================================================
%% Query Operations
%% =============================================================================

%% @doc Returns true if the flag is set in the target state.
%%
%% Example:
%% ```
%% true = evoq_bit_flags:has(100, 64).
%% false = evoq_bit_flags:has(100, 8).
%% '''
-spec has(flags(), flag()) -> boolean().
has(Target, Flag) ->
    (Target band Flag) =:= Flag.

%% @doc Returns true if the flag is NOT set in the target state.
%%
%% Example:
%% ```
%% false = evoq_bit_flags:has_not(100, 64).
%% true = evoq_bit_flags:has_not(100, 8).
%% '''
-spec has_not(flags(), flag()) -> boolean().
has_not(Target, Flag) ->
    (Target band Flag) =/= Flag.

%% @doc Returns true if ALL flags are set in the target state.
%%
%% Example:
%% ```
%% true = evoq_bit_flags:has_all(100, [4, 32, 64]).
%% false = evoq_bit_flags:has_all(100, [4, 8]).
%% '''
-spec has_all(flags(), [flag()]) -> boolean().
has_all(Target, Flags) ->
    lists:all(fun(Flag) -> has(Target, Flag) end, Flags).

%% @doc Returns true if ANY flag is set in the target state.
%%
%% Example:
%% ```
%% true = evoq_bit_flags:has_any(100, [8, 64]).
%% false = evoq_bit_flags:has_any(100, [1, 2, 8]).
%% '''
-spec has_any(flags(), [flag()]) -> boolean().
has_any(Target, Flags) ->
    lists:any(fun(Flag) -> has(Target, Flag) end, Flags).

%% =============================================================================
%% Conversion Operations
%% =============================================================================

%% @doc Returns a list of flag descriptions that are set in the target state.
%%
%% Example:
%% ```
%% FlagMap = #{0 => <<"None">>, 4 => <<"Completed">>, 32 => <<"Archived">>, 64 => <<"Ready">>},
%% [<<"Completed">>, <<"Archived">>, <<"Ready">>] = evoq_bit_flags:to_list(100, FlagMap).
%% '''
-spec to_list(flags(), flag_map()) -> [binary() | string()].
to_list(0, FlagMap) ->
    case maps:get(0, FlagMap, undefined) of
        undefined -> [];
        Description -> [Description]
    end;
to_list(N, FlagMap) when N > 0 ->
    Keys = lists:sort(maps:keys(FlagMap)),
    Flags = lists:foldl(
        fun(Key, Acc) ->
            case Key > 0 andalso (N band Key) =/= 0 of
                true -> [maps:get(Key, FlagMap) | Acc];
                false -> Acc
            end
        end,
        [],
        Keys
    ),
    lists:reverse(Flags).

%% @doc Returns a comma-separated string of flag descriptions.
%%
%% Example:
%% ```
%% FlagMap = #{4 => <<"Completed">>, 32 => <<"Archived">>, 64 => <<"Ready">>},
%% <<"Completed, Archived, Ready">> = evoq_bit_flags:to_string(100, FlagMap).
%% '''
-spec to_string(flags(), flag_map()) -> binary().
to_string(N, FlagMap) ->
    to_string(N, FlagMap, <<", ">>).

%% @doc Returns a string of flag descriptions with custom separator.
%%
%% Example:
%% ```
%% <<"Completed | Archived | Ready">> = evoq_bit_flags:to_string(100, FlagMap, <<" | ">>).
%% '''
-spec to_string(flags(), flag_map(), binary()) -> binary().
to_string(N, FlagMap, Separator) ->
    Descriptions = to_list(N, FlagMap),
    join_binaries(Descriptions, Separator).

%% @doc Decomposes a number into its power-of-2 components.
%%
%% Example:
%% ```
%% [4, 32, 64] = evoq_bit_flags:decompose(100).
%% [1, 2, 4, 8] = evoq_bit_flags:decompose(15).
%% '''
-spec decompose(flags()) -> [flag()].
decompose(0) ->
    [];
decompose(Target) when Target > 0 ->
    decompose(Target, 1, []).

decompose(0, _Power, Acc) ->
    lists:reverse(Acc);
decompose(Target, Power, Acc) when Power > Target ->
    lists:reverse(Acc);
decompose(Target, Power, Acc) ->
    case (Target band Power) =/= 0 of
        true -> decompose(Target, Power bsl 1, [Power | Acc]);
        false -> decompose(Target, Power bsl 1, Acc)
    end.

%% =============================================================================
%% Analysis Operations
%% =============================================================================

%% @doc Returns the description of the highest set flag.
%%
%% Example:
%% ```
%% <<"Ready">> = evoq_bit_flags:highest(100, #{4 => <<"Completed">>, 32 => <<"Archived">>, 64 => <<"Ready">>}).
%% '''
-spec highest(flags(), flag_map()) -> binary() | string() | undefined.
highest(N, FlagMap) ->
    case to_list(N, FlagMap) of
        [] -> undefined;
        List -> lists:last(List)
    end.

%% @doc Returns the description of the lowest set flag.
%%
%% Example:
%% ```
%% <<"Completed">> = evoq_bit_flags:lowest(100, #{4 => <<"Completed">>, 32 => <<"Archived">>, 64 => <<"Ready">>}).
%% '''
-spec lowest(flags(), flag_map()) -> binary() | string() | undefined.
lowest(N, FlagMap) ->
    case to_list(N, FlagMap) of
        [] -> undefined;
        [Head | _] -> Head
    end.

%% =============================================================================
%% Internal Functions
%% =============================================================================

-spec join_binaries([binary() | string()], binary()) -> binary().
join_binaries([], _Sep) ->
    <<>>;
join_binaries([H], _Sep) ->
    ensure_binary(H);
join_binaries([H | T], Sep) ->
    lists:foldl(
        fun(Item, Acc) ->
            <<Acc/binary, Sep/binary, (ensure_binary(Item))/binary>>
        end,
        ensure_binary(H),
        T
    ).

-spec ensure_binary(binary() | string()) -> binary().
ensure_binary(B) when is_binary(B) -> B;
ensure_binary(S) when is_list(S) -> list_to_binary(S).
