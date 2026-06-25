%% @doc Stateful per-node Decision/Context actor (Part B).
%%
%% The transient aggregate for a dynamic boundary. For a keyed, hot
%% consistency boundary (one seat, one account, one SKU) this actor:
%%
%%   1. Serialises commands for the boundary at one process, so the
%%      store's append condition passes first try instead of N-1
%%      context_changed retries.
%%   2. Caches the folded decision model (or the raw context events) and
%%      updates it incrementally after each successful append — no full
%%      context re-read per command.
%%
%% It is a per-node cache + serialiser, NEVER the correctness authority:
%% reckon-db's append_if_no_tag_matches/4 stays the sole source of truth.
%% A second node, a different decision sharing the boundary's tags, or a
%% direct append can still write — so on context_changed the actor
%% invalidates its cache, re-reads context, and retries. It never trusts
%% its cache as truth.
%%
%% Opt in by implementing evoq_decision:boundary_key/1. Absent ⇒ the
%% stateless optimistic runtime (evoq_decision_runtime) handles it.
%%
%% Context is loaded LAZILY on the first decide: the actor is keyed by
%% boundary, but context/1 takes a command. Contract: for a given
%% boundary_key, context/1 must resolve to the same filter for every
%% command (see evoq_decision:boundary_key/1 docs).
%%
%% @author rgfaber
-module(evoq_decision_actor).
-behaviour(gen_server).

%% API
-export([start_link/3]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2]).

-define(DEFAULT_RETRY_BUDGET, 3).

-record(st, {
    module          :: module(),
    key             :: binary(),
    store_id        :: atom(),
    %% Folded model (folded=true) or the raw context-events list
    %% (folded=false). `undefined' until the first decide loads it.
    model           :: term() | undefined,
    cutoff = -1     :: integer(),
    folded          :: boolean(),
    lifespan        :: module()
}).

%%====================================================================
%% API
%%====================================================================

%% @doc Start an actor for the {Module, Key} boundary.
-spec start_link(module(), binary(), atom()) -> {ok, pid()} | {error, term()}.
start_link(Module, Key, StoreId) ->
    gen_server:start_link(?MODULE, {Module, Key, StoreId}, []).

%%====================================================================
%% gen_server callbacks
%%====================================================================

%% @private
init({Module, Key, StoreId}) ->
    evoq_decision_registry:register(Module, Key, self()),
    Folded = erlang:function_exported(Module, init_decision_model, 0) andalso
             erlang:function_exported(Module, apply_context_event, 2),
    Lifespan = application:get_env(
                 evoq, lifespan_module, evoq_aggregate_lifespan_default),
    State = #st{
        module = Module,
        key = Key,
        store_id = StoreId,
        model = undefined,
        cutoff = -1,
        folded = Folded,
        lifespan = Lifespan
    },
    {ok, State, Lifespan:after_command(#{})}.

%% @private
handle_call({decide, Command}, _From, State0) ->
    case ensure_loaded(Command, State0) of
        {error, Reason} ->
            {reply, {error, Reason}, State0,
             (State0#st.lifespan):after_error(Reason)};
        {ok, State1} ->
            Budget = retry_budget(State1#st.module),
            {Reply, State2} = decide_loop(Command, State1, Budget),
            {reply, Reply, State2, next_timeout(Reply, State2)}
    end;
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_request}, State, next_idle(State)}.

%% @private
handle_cast(_Msg, State) ->
    {noreply, State, next_idle(State)}.

%% @private Idle timeout: passivate (v1: stop and rebuild on next spawn).
handle_info(timeout, State) ->
    case (State#st.lifespan):on_timeout(State#st.model) of
        {ok, infinity}            -> {noreply, State};
        {ok, hibernate}           -> {noreply, State, hibernate};
        {ok, passivate}           -> {stop, normal, State};
        {ok, stop}                -> {stop, normal, State};
        {ok, T} when is_integer(T)-> {noreply, State, T};
        %% Decision-model snapshotting (proposal OQ3) is the documented
        %% extension point here. v1 default: ignore the snapshot, apply
        %% the action — cold boundaries rebuild on next spawn.
        {snapshot, Action}        -> apply_action(Action, State)
    end;
handle_info(_Info, State) ->
    {noreply, State, next_idle(State)}.

%% @private
terminate(_Reason, #st{module = Module, key = Key}) ->
    evoq_decision_registry:unregister(Module, Key),
    ok.

%%====================================================================
%% Internal — decide loop
%%====================================================================

decide_loop(_Command, State, 0) ->
    {{error, retry_budget_exhausted}, State};
decide_loop(Command, State, Retries) ->
    #st{module = Mod, store_id = StoreId, model = Model, cutoff = Cutoff} = State,
    Filter = Mod:context(Command),
    case Mod:decide(Model, Command) of
        {error, _} = DecideError ->
            {DecideError, State};
        {ok, Events} when is_list(Events) ->
            case evoq_event_store:append_if_no_tag_matches(
                   StoreId, Filter, Cutoff, Events) of
                {ok, LastSeq} ->
                    {{ok, Events}, absorb(State, Events, LastSeq)};
                {error, {context_changed, _}} ->
                    %% Cache went stale: re-read context, refresh model +
                    %% cutoff, re-decide (the decision may now differ or
                    %% become an error), bounded by retry budget.
                    case reload(Command, State) of
                        {ok, State2} -> decide_loop(Command, State2, Retries - 1);
                        {error, _} = ReloadError -> {ReloadError, State}
                    end;
                {error, _} = BackendError ->
                    {BackendError, State}
            end
    end.

%% Fold just-appended events into the cache and advance the cutoff to the
%% store's reported high-water — no re-read.
absorb(#st{folded = true, module = Mod, model = Model} = State, Events, LastSeq) ->
    NewModel = lists:foldl(
                 fun(E, M) -> Mod:apply_context_event(M, E) end, Model, Events),
    State#st{model = NewModel, cutoff = LastSeq};
absorb(#st{folded = false, model = Events0} = State, Events, LastSeq) ->
    State#st{model = Events0 ++ Events, cutoff = LastSeq}.

%%====================================================================
%% Internal — context loading
%%====================================================================

ensure_loaded(_Command, #st{model = Model} = State) when Model =/= undefined ->
    {ok, State};
ensure_loaded(Command, State) ->
    reload(Command, State).

reload(Command, #st{module = Mod, store_id = StoreId} = State) ->
    Filter = Mod:context(Command),
    case evoq_decision_runtime:load_context(StoreId, Filter) of
        {ok, Events, Cutoff} ->
            {ok, State#st{model = build_model(State, Events), cutoff = Cutoff}};
        {error, _} = Error ->
            Error
    end.

build_model(#st{folded = true, module = Mod}, Events) ->
    lists:foldl(fun(E, M) -> Mod:apply_context_event(M, E) end,
                Mod:init_decision_model(), Events);
build_model(#st{folded = false}, Events) ->
    Events.

%%====================================================================
%% Internal — lifespan / timeouts
%%====================================================================

next_timeout({ok, _}, State) ->
    (State#st.lifespan):after_command(#{});
next_timeout({error, Reason}, State) ->
    (State#st.lifespan):after_error(Reason).

next_idle(State) ->
    (State#st.lifespan):after_command(#{}).

apply_action(passivate, State) -> {stop, normal, State};
apply_action(stop, State)      -> {stop, normal, State};
apply_action(hibernate, State) -> {noreply, State, hibernate};
apply_action(infinity, State)  -> {noreply, State};
apply_action(T, State) when is_integer(T) -> {noreply, State, T}.

retry_budget(Mod) ->
    case erlang:function_exported(Mod, retry_budget, 0) of
        true  -> Mod:retry_budget();
        false -> ?DEFAULT_RETRY_BUDGET
    end.
