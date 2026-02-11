%% @doc Command behavior for evoq.
%%
%% Commands represent intentions to change state. They are:
%% - Imperative (present tense): open_account, deposit_money
%% - Targeted at a specific aggregate
%% - Validated before dispatch
%%
%% == Callbacks ==
%%
%% Optional:
%% - validate(Command) -> ok | {error, Reason}
%%
%% @author rgfaber
-module(evoq_command).

-include("evoq.hrl").

%% Optional callbacks
-callback validate(Command :: map()) -> ok | {error, Reason :: term()}.

-optional_callbacks([validate/1]).

%% API
-export([new/4, new/5]).
-export([validate/1]).
-export([ensure_id/1]).
-export([get_id/1, get_type/1, get_aggregate_id/1, get_aggregate_type/1]).
-export([get_payload/1, get_metadata/1]).
-export([get_idempotency_key/1, set_idempotency_key/2]).
-export([set_causation_id/2, set_correlation_id/2]).

%%====================================================================
%% API
%%====================================================================

%% @doc Create a new command.
-spec new(atom(), atom(), binary(), map()) -> #evoq_command{}.
new(CommandType, AggregateType, AggregateId, Payload) ->
    new(CommandType, AggregateType, AggregateId, Payload, #{}).

%% @doc Create a new command with metadata.
-spec new(atom(), atom(), binary(), map(), map()) -> #evoq_command{}.
new(CommandType, AggregateType, AggregateId, Payload, Metadata) ->
    #evoq_command{
        command_id = generate_id(),
        command_type = CommandType,
        aggregate_type = AggregateType,
        aggregate_id = AggregateId,
        payload = Payload,
        metadata = Metadata,
        causation_id = undefined,
        correlation_id = generate_id()
    }.

%% @doc Validate a command using its module's validate/1 callback.
-spec validate(#evoq_command{}) -> ok | {error, term()}.
validate(Command) ->
    %% First validate required fields
    case validate_required_fields(Command) of
        ok ->
            %% Then try module-specific validation
            validate_with_module(Command);
        Error ->
            Error
    end.

%% @private
validate_required_fields(#evoq_command{command_type = undefined}) ->
    {error, missing_command_type};
validate_required_fields(#evoq_command{aggregate_type = undefined}) ->
    {error, missing_aggregate_type};
validate_required_fields(#evoq_command{aggregate_id = undefined}) ->
    {error, missing_aggregate_id};
validate_required_fields(_Command) ->
    ok.

%% @private
validate_with_module(#evoq_command{command_type = CommandType, payload = Payload}) ->
    %% Try to find a command module with validate/1
    case code:ensure_loaded(CommandType) of
        {module, CommandType} ->
            case erlang:function_exported(CommandType, validate, 1) of
                true -> CommandType:validate(Payload);
                false -> ok
            end;
        _ ->
            ok
    end.

%% @doc Get the command ID.
-spec get_id(#evoq_command{}) -> binary().
get_id(#evoq_command{command_id = Id}) -> Id.

%% @doc Get the command type.
-spec get_type(#evoq_command{}) -> atom().
get_type(#evoq_command{command_type = Type}) -> Type.

%% @doc Get the aggregate ID.
-spec get_aggregate_id(#evoq_command{}) -> binary().
get_aggregate_id(#evoq_command{aggregate_id = Id}) -> Id.

%% @doc Get the aggregate type.
-spec get_aggregate_type(#evoq_command{}) -> atom().
get_aggregate_type(#evoq_command{aggregate_type = Type}) -> Type.

%% @doc Get the command payload.
-spec get_payload(#evoq_command{}) -> map().
get_payload(#evoq_command{payload = Payload}) -> Payload.

%% @doc Get the command metadata.
-spec get_metadata(#evoq_command{}) -> map().
get_metadata(#evoq_command{metadata = Metadata}) -> Metadata.

%% @doc Set the causation ID.
-spec set_causation_id(binary(), #evoq_command{}) -> #evoq_command{}.
set_causation_id(CausationId, Command) ->
    Command#evoq_command{causation_id = CausationId}.

%% @doc Set the correlation ID.
-spec set_correlation_id(binary(), #evoq_command{}) -> #evoq_command{}.
set_correlation_id(CorrelationId, Command) ->
    Command#evoq_command{correlation_id = CorrelationId}.

%% @doc Get the idempotency key (may be undefined).
-spec get_idempotency_key(#evoq_command{}) -> binary() | undefined.
get_idempotency_key(#evoq_command{idempotency_key = Key}) -> Key.

%% @doc Set a caller-provided idempotency key for deduplication.
-spec set_idempotency_key(binary(), #evoq_command{}) -> #evoq_command{}.
set_idempotency_key(Key, Command) ->
    Command#evoq_command{idempotency_key = Key}.

%% @doc Ensure the command has a command_id. If undefined, auto-generates one.
-spec ensure_id(#evoq_command{}) -> #evoq_command{}.
ensure_id(#evoq_command{command_id = undefined} = Command) ->
    Command#evoq_command{command_id = generate_id()};
ensure_id(Command) ->
    Command.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
generate_id() ->
    Bytes = crypto:strong_rand_bytes(16),
    binary:encode_hex(Bytes).
