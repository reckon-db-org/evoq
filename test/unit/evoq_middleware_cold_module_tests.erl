%% @doc A middleware named in the chain always runs (evoq#39).
%%%
%%% `evoq_middleware:chain/3' skipped a stage when
%%% `erlang:function_exported/3' said the module did not have it. That function
%%% answers false for a module the VM has not LOADED, not only for one that does
%%% not export the stage, so a middleware that nothing had called yet was
%%% skipped. Skipping it means never calling it, which means it stays unloaded,
%%% which means it is skipped on every dispatch after that -- in interactive
%%% code-loading mode, for as long as the node runs.
%%%
%%% Middleware arrives as bare atoms from `application:get_env(evoq, middleware,
%%% [])' or a dispatch's own `middleware' option, and nothing in evoq calls
%%% those modules first. So this is not a theoretical ordering: a deny-all
%%% `before_dispatch' -- an authorization, a validation, a rate limit -- lets
%%% the command through on a node that has not happened to load it yet.
%%%
%%% A stage the module does not export is still skipped: that is a middleware
%%% implementing one of the three optional callbacks and nothing else, which is
%%% the documented behaviour and must not change. Two other shapes are refused
%%% instead: a NAME THAT CANNOT BE LOADED (`middleware_not_loadable'), and a
%%% module that loads but exports NONE of the three stages (`not_a_middleware'),
%%% which is what configuration naming an API module looks like.
-module(evoq_middleware_cold_module_tests).

-include_lib("eunit/include/eunit.hrl").
-include("evoq.hrl").

-define(DENY_ALL, evoq_middleware_deny_all).
-define(AFTER_ONLY, evoq_middleware_after_only).

%%====================================================================
%% The defect: a cold module was skipped, and a deny-all let the command run
%%====================================================================

a_cold_middleware_is_still_run_test() ->
    with_the_middleware_unloaded(fun() ->
        %% Cold, proven on the VM and not only on the export.
        ?assertEqual(false, code:is_loaded(?DENY_ALL)),
        Pipeline = evoq_middleware:chain(#evoq_pipeline{}, before_dispatch, [?DENY_ALL]),
        ?assert(evoq_middleware:halted(Pipeline)),
        ?assertEqual({error, denied}, evoq_middleware:get_response(Pipeline))
    end).

%%====================================================================
%% A name that cannot be loaded refuses the dispatch
%%====================================================================

an_unloadable_middleware_refuses_the_dispatch_test() ->
    Name = evoq_no_such_middleware_module,
    ?assertEqual(false, code:is_loaded(Name)),
    Pipeline = evoq_middleware:chain(#evoq_pipeline{}, before_dispatch, [Name]),
    ?assert(evoq_middleware:halted(Pipeline)),
    ?assertMatch({error, {middleware_not_loadable, Name, _}},
                 evoq_middleware:get_response(Pipeline)).

%%====================================================================
%% The half that must not change: a stage the module does not export is a no-op
%%====================================================================

a_middleware_without_the_stage_is_still_skipped_test() ->
    %% Exports after_dispatch/1 and not before_dispatch/1: one of the three
    %% optional callbacks, which is a middleware and is skipped at this stage.
    _ = code:ensure_loaded(?AFTER_ONLY),
    Pipeline = #evoq_pipeline{assigns = #{seen => before}},
    ?assertEqual(Pipeline, evoq_middleware:chain(Pipeline, before_dispatch, [?AFTER_ONLY])).

%% A middleware that exports a DIFFERENT stage is skipped for this one too, and
%% the one after it still runs -- skipping is per stage, not per module.
a_middleware_with_another_stage_does_not_stop_the_chain_test() ->
    _ = code:ensure_loaded(?AFTER_ONLY),
    with_the_middleware_unloaded(fun() ->
        Pipeline = evoq_middleware:chain(#evoq_pipeline{}, before_dispatch,
                                         [?AFTER_ONLY, ?DENY_ALL]),
        ?assertEqual({error, denied}, evoq_middleware:get_response(Pipeline))
    end).

%%====================================================================
%% A module that is not a middleware at all refuses the dispatch
%%====================================================================

%% Fable round 1, R1: a module that LOADS but exports none of the three stages
%% is not middleware. Configuration that names an API module instead of the
%% middleware beside it used to be skipped, which is a missing check that looks
%% exactly like a passing one.
a_module_that_is_not_a_middleware_refuses_the_dispatch_test() ->
    %% `lists' is loaded, and exports none of before_dispatch/1,
    %% after_dispatch/1 or after_failure/1.
    ?assertMatch({module, lists}, code:ensure_loaded(lists)),
    Pipeline = evoq_middleware:chain(#evoq_pipeline{}, before_dispatch, [lists]),
    ?assert(evoq_middleware:halted(Pipeline)),
    ?assertEqual({error, {not_a_middleware, lists}},
                 evoq_middleware:get_response(Pipeline)).

%% The refusal is the same in an after_* chain, where it arrives AFTER the
%% command has run and overwrites the response the pipeline already carried.
a_module_that_is_not_a_middleware_refuses_an_after_stage_too_test() ->
    Pipeline0 = evoq_middleware:respond({ok, 3, [an_event]}, #evoq_pipeline{}),
    Pipeline = evoq_middleware:chain(Pipeline0, after_dispatch, [lists]),
    ?assert(evoq_middleware:halted(Pipeline)),
    ?assertEqual({error, {not_a_middleware, lists}},
                 evoq_middleware:get_response(Pipeline)).

%%====================================================================

%% Deleted from the VM, and proven cold: `function_exported/3' would answer
%% false for an exported function of a loaded module too, so the check has to be
%% `code:is_loaded/1' or the test could pass for the wrong reason.
with_the_middleware_unloaded(Test) ->
    _ = code:purge(?DENY_ALL),
    _ = code:delete(?DENY_ALL),
    _ = code:purge(?DENY_ALL),
    Test().
