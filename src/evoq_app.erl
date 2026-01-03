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
-spec start(application:start_type(), term()) -> {ok, pid()} | {error, term()}.
start(_StartType, _StartArgs) ->
    %% Ensure pg is started for aggregate registry
    case pg:start_link(evoq_pg) of
        {ok, _} -> ok;
        {error, {already_started, _}} -> ok
    end,
    evoq_sup:start_link().

%% @doc Stop the evoq application.
-spec stop(term()) -> ok.
stop(_State) ->
    ok.
