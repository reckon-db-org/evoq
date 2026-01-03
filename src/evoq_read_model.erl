%% @doc Read model store behavior for evoq.
%%
%% Provides an abstract interface for read model storage.
%% Projections use this behavior to persist query-optimized data.
%%
%% == Design Principles ==
%%
%% - Read models are optimized for queries (no joins, no calculations)
%% - All calculations happen in projections, not queries
%% - Read models can be rebuilt from events at any time
%%
%% == Callbacks ==
%%
%% Required:
%% - init(Config) -> {ok, State}
%% - get(Key, State) -> {ok, Value} | {error, not_found}
%% - put(Key, Value, State) -> {ok, NewState}
%% - delete(Key, State) -> {ok, NewState}
%%
%% Optional:
%% - list(Prefix, State) -> {ok, [{Key, Value}]}
%% - clear(State) -> {ok, NewState}
%%
%% @author rgfaber
-module(evoq_read_model).

%% Required callbacks
-callback init(Config :: map()) -> {ok, State :: term()} | {error, Reason :: term()}.

-callback get(Key :: term(), State :: term()) ->
    {ok, Value :: term()} | {error, not_found} | {error, Reason :: term()}.

-callback put(Key :: term(), Value :: term(), State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

-callback delete(Key :: term(), State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

%% Optional callbacks
-callback list(Prefix :: term(), State :: term()) ->
    {ok, [{Key :: term(), Value :: term()}]} | {error, Reason :: term()}.

-callback clear(State :: term()) ->
    {ok, NewState :: term()} | {error, Reason :: term()}.

-optional_callbacks([list/2, clear/1]).

%% API
-export([new/2]).
-export([get/2, put/3, delete/2]).
-export([list/2, clear/1]).
-export([get_checkpoint/1, set_checkpoint/2]).

-record(read_model, {
    module :: atom(),
    state :: term(),
    checkpoint = 0 :: non_neg_integer()
}).

-opaque read_model() :: #read_model{}.
-export_type([read_model/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new read model instance.
-spec new(atom(), map()) -> {ok, read_model()} | {error, term()}.
new(Module, Config) ->
    case Module:init(Config) of
        {ok, State} ->
            {ok, #read_model{module = Module, state = State}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Get a value from the read model.
-spec get(term(), read_model()) -> {ok, term()} | {error, not_found | term()}.
get(Key, #read_model{module = Module, state = State}) ->
    Module:get(Key, State).

%% @doc Put a value into the read model.
-spec put(term(), term(), read_model()) -> {ok, read_model()} | {error, term()}.
put(Key, Value, #read_model{module = Module, state = State} = RM) ->
    case Module:put(Key, Value, State) of
        {ok, NewState} ->
            {ok, RM#read_model{state = NewState}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc Delete a value from the read model.
-spec delete(term(), read_model()) -> {ok, read_model()} | {error, term()}.
delete(Key, #read_model{module = Module, state = State} = RM) ->
    case Module:delete(Key, State) of
        {ok, NewState} ->
            {ok, RM#read_model{state = NewState}};
        {error, Reason} ->
            {error, Reason}
    end.

%% @doc List all key-value pairs matching a prefix.
-spec list(term(), read_model()) -> {ok, [{term(), term()}]} | {error, term()}.
list(Prefix, #read_model{module = Module, state = State}) ->
    case erlang:function_exported(Module, list, 2) of
        true ->
            Module:list(Prefix, State);
        false ->
            {error, not_implemented}
    end.

%% @doc Clear all data from the read model.
-spec clear(read_model()) -> {ok, read_model()} | {error, term()}.
clear(#read_model{module = Module, state = State} = RM) ->
    case erlang:function_exported(Module, clear, 1) of
        true ->
            case Module:clear(State) of
                {ok, NewState} ->
                    {ok, RM#read_model{state = NewState, checkpoint = 0}};
                {error, Reason} ->
                    {error, Reason}
            end;
        false ->
            {error, not_implemented}
    end.

%% @doc Get the current checkpoint position.
-spec get_checkpoint(read_model()) -> non_neg_integer().
get_checkpoint(#read_model{checkpoint = Checkpoint}) ->
    Checkpoint.

%% @doc Set the checkpoint position.
-spec set_checkpoint(non_neg_integer(), read_model()) -> read_model().
set_checkpoint(Position, RM) ->
    RM#read_model{checkpoint = Position}.
