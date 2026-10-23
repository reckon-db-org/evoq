%% An aggregate written from the docs (init/1, execute/2, apply/2) must
%% compile without a warning, so state_module/0 is optional (evoq#28).
-module(evoq_aggregate_callbacks_tests).

-include_lib("eunit/include/eunit.hrl").

required_callbacks_are_the_three_evoq_calls_test() ->
    Required = evoq_aggregate:behaviour_info(callbacks)
               -- evoq_aggregate:behaviour_info(optional_callbacks),
    ?assertEqual(lists:sort([{init, 1}, {execute, 2}, {apply, 2}]),
                 lists:sort(Required)).

state_module_is_optional_test() ->
    ?assert(lists:member({state_module, 0},
                         evoq_aggregate:behaviour_info(optional_callbacks))).
