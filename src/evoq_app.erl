%% @doc evoq application module.
%%
%% Entry point for the evoq CQRS/Event Sourcing framework.
%% Starts the top-level supervisor and initializes the pg groups
%% for aggregate registry and event routing.
%%
%% @author rgfaber
-module(evoq_app).
-behaviour(application).

%% Application callbacks
-export([start/2, stop/1]).

%%====================================================================
%% Application callbacks
%%====================================================================

%% @doc Start the evoq application.
%%
%% ⚠ THE CONFIGURED MIDDLEWARE CHAIN IS RESOLVED BEFORE ANYTHING STARTS
%% (evoq#42). A name in `application:get_env(evoq, middleware, [])' that cannot
%% be loaded, or that is not a middleware at all, fails this start: the operator
%% finds out from the boot that refused rather than from the caller whose first
%% command was refused -- or, from an `after_*' chain, from the caller whose
%% command had already been accepted and stored before the refusal arrived.
%%
%% A chain carried in a dispatch's own `middleware' option cannot be known here
%% and keeps the dispatch-time refusal evoq#39 put in place.
%% See: evoq_middleware:resolve_chain/1.
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    case evoq_middleware:resolve_chain(configured_middleware()) of
        ok -> start_supervisor();
        {error, Reason} -> {error, {invalid_middleware, Reason}}
    end.

%% @private
start_supervisor() ->
    %% Ensure pg is started for aggregate registry
    case pg:start_link(evoq_pg) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    evoq_sup:start_link().

%% @private
configured_middleware() ->
    application:get_env(evoq, middleware, []).

%% @doc Stop the evoq application.
-spec stop(term()) -> ok.
stop(_State) ->
    ok.
