%% @doc Middleware behavior for command dispatch pipeline.
%%
%% Middleware can intercept commands at three stages:
%% - before_dispatch: Before command reaches aggregate
%% - after_dispatch: After successful command execution
%% - after_failure: After command execution fails
%%
%% Middleware can:
%% - Add data to pipeline assigns
%% - Halt the pipeline (prevents further processing)
%% - Modify the response
%%
%% @author rgfaber
-module(evoq_middleware).

%% This module's own halt/1 is the pipeline's, not the BIF that stops the VM.
%% Without this, calling it unqualified inside the module is ambiguous.
-compile({no_auto_import, [halt/1]}).

-include("evoq.hrl").

%% Behavior callbacks
-callback before_dispatch(Pipeline :: #evoq_pipeline{}) -> #evoq_pipeline{}.
-callback after_dispatch(Pipeline :: #evoq_pipeline{}) -> #evoq_pipeline{}.
-callback after_failure(Pipeline :: #evoq_pipeline{}) -> #evoq_pipeline{}.

-optional_callbacks([before_dispatch/1, after_dispatch/1, after_failure/1]).

%% API
-export([chain/3]).
-export([assign/3, get_assign/2, get_assign/3]).
-export([halt/1, halted/1]).
-export([respond/2, get_response/1]).

%%====================================================================
%% API
%%====================================================================

%% @doc Chain a pipeline through a list of middleware modules.
%%
%% ⚠ A MIDDLEWARE IN THE CHAIN ALWAYS RUNS (evoq#39). This used to call a stage
%% only when `erlang:function_exported/3' said the module had it, and that
%% function answers false for a module the VM has not LOADED -- not only for one
%% that does not export the stage. Middleware arrives here as bare atoms from
%% `application:get_env(evoq, middleware, [])' or a dispatch's own `middleware'
%% option, and nothing in evoq calls those modules first, so a middleware that
%% nothing had touched yet was skipped. Skipping it means never calling it,
%% which means it stays unloaded, which means it is skipped on every dispatch
%% after that. A deny-all `before_dispatch' -- an authorization, a validation, a
%% rate limit -- let commands through on any node that had not happened to load
%% it.
%%
%% The module is therefore loaded first, as `evoq_command:validate_with_module/1'
%% and `evoq_event_store:new_stream_id/1' already do. Two answers follow from
%% that, and they are different:
%%
%%   - a stage the module does not export is still SKIPPED. That is a middleware
%%     implementing one of the three optional callbacks and nothing else, which
%%     is the documented contract;
%%   - a module that cannot be loaded REFUSES THE DISPATCH: the pipeline halts
%%     with `{error, {middleware_not_loadable, Module, Reason}}'. A name in the
%%     chain that is not there is a misconfiguration, not an opt-out, and
%%     skipping it would make a missing security check look like a passing one.
-spec chain(#evoq_pipeline{}, atom(), [atom()]) -> #evoq_pipeline{}.
chain(Pipeline, _Stage, []) ->
    Pipeline;
chain(#evoq_pipeline{halted = true} = Pipeline, _Stage, _Middleware) ->
    Pipeline;
chain(Pipeline, Stage, [Module | Rest]) ->
    case run_stage(Module, Stage, Pipeline) of
        {ok, NewPipeline} ->
            chain(NewPipeline, Stage, Rest);
        {error, Reason} ->
            respond({error, Reason}, halt(Pipeline))
    end.

%% @private
run_stage(Module, Stage, Pipeline) ->
    case code:ensure_loaded(Module) of
        {module, Module} -> run_stage_loaded(Module, Stage, Pipeline);
        {error, Reason} -> {error, {middleware_not_loadable, Module, Reason}}
    end.

%% @private
%% Loaded and present: run it. Loaded and the stage not exported: the middleware
%% does not act at this point, and skipping it is the contract, not an accident.
run_stage_loaded(Module, Stage, Pipeline) ->
    case erlang:function_exported(Module, Stage, 1) of
        true -> {ok, Module:Stage(Pipeline)};
        false -> {ok, Pipeline}
    end.

%% @doc Assign a value to the pipeline.
-spec assign(atom(), term(), #evoq_pipeline{}) -> #evoq_pipeline{}.
assign(Key, Value, #evoq_pipeline{assigns = Assigns} = Pipeline) ->
    Pipeline#evoq_pipeline{assigns = Assigns#{Key => Value}}.

%% @doc Get an assigned value from the pipeline.
-spec get_assign(atom(), #evoq_pipeline{}) -> term() | undefined.
get_assign(Key, Pipeline) ->
    get_assign(Key, Pipeline, undefined).

%% @doc Get an assigned value with a default.
-spec get_assign(atom(), #evoq_pipeline{}, term()) -> term().
get_assign(Key, #evoq_pipeline{assigns = Assigns}, Default) ->
    maps:get(Key, Assigns, Default).

%% @doc Halt the pipeline.
-spec halt(#evoq_pipeline{}) -> #evoq_pipeline{}.
halt(Pipeline) ->
    Pipeline#evoq_pipeline{halted = true}.

%% @doc Check if the pipeline is halted.
-spec halted(#evoq_pipeline{}) -> boolean().
halted(#evoq_pipeline{halted = Halted}) ->
    Halted.

%% @doc Set the pipeline response.
-spec respond(term(), #evoq_pipeline{}) -> #evoq_pipeline{}.
respond(Response, Pipeline) ->
    Pipeline#evoq_pipeline{response = Response}.

%% @doc Get the pipeline response.
-spec get_response(#evoq_pipeline{}) -> term().
get_response(#evoq_pipeline{response = Response}) ->
    Response.
