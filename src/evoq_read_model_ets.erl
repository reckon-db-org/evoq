%% @doc ETS-based read model store implementation.
%%
%% Default in-memory implementation of evoq_read_model behavior.
%% Suitable for development, testing, and small-scale deployments.
%%
%% == Configuration ==
%%
%% - name: ETS table name (default: auto-generated)
%% - type: ETS table type (default: set)
%% - access: public | protected | private (default: protected)
%%
%% @author rgfaber
-module(evoq_read_model_ets).
-behaviour(evoq_read_model).

%% Behavior callbacks
-export([init/1, get/2, put/3, delete/2]).
-export([list/2, clear/1]).

-record(state, {
    table :: ets:tid()
}).

%%====================================================================
%% Behavior callbacks
%%====================================================================

%% @doc Initialize ETS-backed read model.
-spec init(map()) -> {ok, #state{}} | {error, term()}.
init(Config) ->
    Type = maps:get(type, Config, set),
    Access = maps:get(access, Config, public),

    try
        %% Use unnamed table (returns tid) for isolation between instances
        Table = case maps:get(name, Config, undefined) of
            undefined ->
                %% Anonymous table
                ets:new(?MODULE, [Type, Access, {read_concurrency, true}]);
            Name when is_atom(Name) ->
                %% Named table
                ets:new(Name, [Type, Access, named_table, {read_concurrency, true}])
        end,
        {ok, #state{table = Table}}
    catch
        error:Reason ->
            {error, Reason}
    end.

%% @doc Get a value by key.
-spec get(term(), #state{}) -> {ok, term()} | {error, not_found}.
get(Key, #state{table = Table}) ->
    case ets:lookup(Table, Key) of
        [{Key, Value}] ->
            {ok, Value};
        [] ->
            {error, not_found}
    end.

%% @doc Store a key-value pair.
-spec put(term(), term(), #state{}) -> {ok, #state{}}.
put(Key, Value, #state{table = Table} = State) ->
    true = ets:insert(Table, {Key, Value}),
    {ok, State}.

%% @doc Delete a key.
-spec delete(term(), #state{}) -> {ok, #state{}}.
delete(Key, #state{table = Table} = State) ->
    true = ets:delete(Table, Key),
    {ok, State}.

%% @doc List all key-value pairs with matching prefix.
%% For ETS, prefix matching works on tuple/list keys.
-spec list(term(), #state{}) -> {ok, [{term(), term()}]}.
list(Prefix, #state{table = Table}) ->
    MatchSpec = case Prefix of
        all ->
            [{{'$1', '$2'}, [], [{{'$1', '$2'}}]}];
        _ when is_binary(Prefix) ->
            %% Binary prefix match
            PrefixSize = byte_size(Prefix),
            [{{'$1', '$2'},
              [{'andalso',
                {is_binary, '$1'},
                {'=:=', {binary_part, '$1', 0, PrefixSize}, Prefix}}],
              [{{'$1', '$2'}}]}];
        _ when is_tuple(Prefix) ->
            %% Tuple prefix match (first element)
            FirstElement = element(1, Prefix),
            [{{'$1', '$2'},
              [{'andalso',
                {is_tuple, '$1'},
                {'=:=', {element, 1, '$1'}, FirstElement}}],
              [{{'$1', '$2'}}]}];
        _ ->
            %% No prefix filtering
            [{{'$1', '$2'}, [], [{{'$1', '$2'}}]}]
    end,
    Results = ets:select(Table, MatchSpec),
    {ok, Results}.

%% @doc Clear all data from the table.
-spec clear(#state{}) -> {ok, #state{}}.
clear(#state{table = Table} = State) ->
    true = ets:delete_all_objects(Table),
    {ok, State}.
