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
-spec chain(#evoq_pipeline{}, atom(), [atom()]) -> #evoq_pipeline{}.
chain(Pipeline, _Stage, []) ->
    Pipeline;
chain(#evoq_pipeline{halted = true} = Pipeline, _Stage, _Middleware) ->
    Pipeline;
chain(Pipeline, Stage, [Module | Rest]) ->
    NewPipeline = case erlang:function_exported(Module, Stage, 1) of
        true -> Module:Stage(Pipeline);
        false -> Pipeline
    end,
    chain(NewPipeline, Stage, Rest).

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
