%% @doc Scripted failures for the projection recovery tests.
%%
%% Kept apart from both probe projections so they can share one script: the
%% probe that exports on_error/4 and the one that does not must fail on the
%% same event, or the two tests would not be testing the same thing.
-module(evoq_projection_recovery_script).

-export([reset/0, fail_times/2, take_failure/1, set_action/1, action/0]).

reset() ->
    persistent_term:put({?MODULE, failures}, #{}),
    persistent_term:put({?MODULE, action}, skip).

%% Fail event N Count more times, then let it through.
fail_times(N, Count) ->
    Failures = persistent_term:get({?MODULE, failures}, #{}),
    persistent_term:put({?MODULE, failures}, Failures#{N => Count}).

%% Consume one scripted failure for event N, if any is left.
take_failure(N) ->
    case persistent_term:get({?MODULE, failures}, #{}) of
        #{N := Count} = Failures when Count > 0 ->
            persistent_term:put({?MODULE, failures}, Failures#{N => Count - 1}),
            true;
        _ ->
            false
    end.

set_action(Action) ->
    persistent_term:put({?MODULE, action}, Action).

action() ->
    persistent_term:get({?MODULE, action}, skip).
