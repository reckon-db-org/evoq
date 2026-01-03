%% @doc Memory pressure monitor for adaptive TTL.
%%
%% Monitors system memory usage and adjusts aggregate TTLs
%% to prevent unbounded memory growth.
%%
%% Pressure Levels:
%% <ul>
%% <li>normal - Memory below 70 percent, TTL factor 1.0x</li>
%% <li>elevated - Memory 70-85 percent, TTL factor 0.5x</li>
%% <li>critical - Memory above 85 percent, TTL factor 0.1x</li>
%% </ul>
%%
%% @author rgfaber
-module(evoq_memory_monitor).
-behaviour(gen_server).

-include("evoq_telemetry.hrl").

%% API
-export([start_link/0, start_link/1]).
-export([get_pressure_level/0]).
-export([get_ttl_factor/0]).
-export([get_stats/0]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(SERVER, ?MODULE).
-define(DEFAULT_CHECK_INTERVAL, 10000).  %% 10 seconds
-define(DEFAULT_ELEVATED_THRESHOLD, 0.70).
-define(DEFAULT_CRITICAL_THRESHOLD, 0.85).

-type pressure_level() :: normal | elevated | critical.

-record(state, {
    check_interval :: pos_integer(),
    elevated_threshold :: float(),
    critical_threshold :: float(),
    current_level :: pressure_level(),
    ttl_factor :: float(),
    last_check :: integer(),
    memory_usage :: float()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the memory monitor with default config.
-spec start_link() -> {ok, pid()} | {error, term()}.
start_link() ->
    start_link(#{}).

%% @doc Start the memory monitor with custom config.
%% Options:
%% - check_interval: Milliseconds between checks (default: 10000)
%% - elevated_threshold: Memory % for elevated level (default: 0.70)
%% - critical_threshold: Memory % for critical level (default: 0.85)
-spec start_link(map()) -> {ok, pid()} | {error, term()}.
start_link(Config) ->
    gen_server:start_link({local, ?SERVER}, ?MODULE, Config, []).

%% @doc Get the current memory pressure level.
-spec get_pressure_level() -> pressure_level().
get_pressure_level() ->
    gen_server:call(?SERVER, get_pressure_level).

%% @doc Get the current TTL factor (0.0 - 1.0).
-spec get_ttl_factor() -> float().
get_ttl_factor() ->
    gen_server:call(?SERVER, get_ttl_factor).

%% @doc Get memory monitor statistics.
-spec get_stats() -> map().
get_stats() ->
    gen_server:call(?SERVER, get_stats).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init(Config) ->
    CheckInterval = maps:get(check_interval, Config, ?DEFAULT_CHECK_INTERVAL),
    ElevatedThreshold = maps:get(elevated_threshold, Config, ?DEFAULT_ELEVATED_THRESHOLD),
    CriticalThreshold = maps:get(critical_threshold, Config, ?DEFAULT_CRITICAL_THRESHOLD),

    State = #state{
        check_interval = CheckInterval,
        elevated_threshold = ElevatedThreshold,
        critical_threshold = CriticalThreshold,
        current_level = normal,
        ttl_factor = 1.0,
        last_check = erlang:system_time(millisecond),
        memory_usage = 0.0
    },

    %% Schedule first check
    erlang:send_after(CheckInterval, self(), check_memory),

    {ok, State}.

%% @private
handle_call(get_pressure_level, _From, #state{current_level = Level} = State) ->
    {reply, Level, State};

handle_call(get_ttl_factor, _From, #state{ttl_factor = Factor} = State) ->
    {reply, Factor, State};

handle_call(get_stats, _From, State) ->
    Stats = #{
        pressure_level => State#state.current_level,
        ttl_factor => State#state.ttl_factor,
        memory_usage => State#state.memory_usage,
        last_check => State#state.last_check,
        elevated_threshold => State#state.elevated_threshold,
        critical_threshold => State#state.critical_threshold
    },
    {reply, Stats, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State}.

%% @private
handle_info(check_memory, State) ->
    NewState = do_check_memory(State),

    %% Schedule next check
    erlang:send_after(State#state.check_interval, self(), check_memory),

    {noreply, NewState};

handle_info(_Info, State) ->
    {noreply, State}.

%% @private
terminate(_Reason, _State) ->
    ok.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
do_check_memory(#state{
    elevated_threshold = ElevatedThreshold,
    critical_threshold = CriticalThreshold,
    current_level = OldLevel
} = State) ->
    %% Get memory usage
    MemoryUsage = get_memory_usage(),

    %% Determine pressure level
    NewLevel = case MemoryUsage of
        U when U >= CriticalThreshold -> critical;
        U when U >= ElevatedThreshold -> elevated;
        _ -> normal
    end,

    %% Calculate TTL factor
    NewFactor = case NewLevel of
        normal -> 1.0;
        elevated -> 0.5;
        critical -> 0.1
    end,

    %% Emit telemetry if level changed
    case NewLevel =/= OldLevel of
        true ->
            telemetry:execute(?TELEMETRY_MEMORY_PRESSURE, #{
                memory_usage => MemoryUsage
            }, #{
                old_level => OldLevel,
                new_level => NewLevel
            }),

            telemetry:execute(?TELEMETRY_MEMORY_TTL_ADJUSTED, #{
                ttl_factor => NewFactor
            }, #{
                pressure_level => NewLevel
            });
        false ->
            ok
    end,

    State#state{
        current_level = NewLevel,
        ttl_factor = NewFactor,
        memory_usage = MemoryUsage,
        last_check = erlang:system_time(millisecond)
    }.

%% @private
%% Get current memory usage as a fraction (0.0 - 1.0)
get_memory_usage() ->
    MemoryInfo = erlang:memory(),
    Total = proplists:get_value(total, MemoryInfo, 0),
    %% Try to get system limit
    case get_system_memory_limit() of
        {ok, Limit} when Limit > 0 ->
            Total / Limit;
        _ ->
            %% Fallback: estimate based on a reasonable default
            0.3
    end.

%% @private
%% Try to get system memory limit
get_system_memory_limit() ->
    try
        case os:type() of
            {unix, linux} ->
                %% Try to read from /proc/meminfo
                case file:read_file("/proc/meminfo") of
                    {ok, Content} ->
                        parse_meminfo(Content);
                    _ ->
                        {error, not_available}
                end;
            _ ->
                %% For other systems, use a reasonable default
                {ok, 8 * 1024 * 1024 * 1024}  %% 8GB default
        end
    catch
        _:_ ->
            {error, not_available}
    end.

%% @private
parse_meminfo(Content) ->
    Lines = binary:split(Content, <<"\n">>, [global]),
    parse_meminfo_lines(Lines).

parse_meminfo_lines([]) ->
    {error, not_found};
parse_meminfo_lines([Line | Rest]) ->
    case binary:match(Line, <<"MemTotal:">>) of
        {0, _} ->
            %% Found MemTotal line
            case re:run(Line, <<"([0-9]+)">>, [{capture, [1], binary}]) of
                {match, [ValueBin]} ->
                    %% Value is in kB
                    Value = binary_to_integer(ValueBin) * 1024,
                    {ok, Value};
                _ ->
                    parse_meminfo_lines(Rest)
            end;
        _ ->
            parse_meminfo_lines(Rest)
    end.
