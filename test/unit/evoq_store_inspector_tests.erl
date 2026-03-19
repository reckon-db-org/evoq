-module(evoq_store_inspector_tests).
-include_lib("eunit/include/eunit.hrl").

exports_test() ->
    Exports = evoq_store_inspector:module_info(exports),
    ?assert(lists:member({store_stats, 1}, Exports)),
    ?assert(lists:member({list_all_snapshots, 1}, Exports)),
    ?assert(lists:member({list_subscriptions, 1}, Exports)),
    ?assert(lists:member({subscription_lag, 2}, Exports)),
    ?assert(lists:member({event_type_summary, 1}, Exports)),
    ?assert(lists:member({stream_info, 2}, Exports)).

%% When no adapter is configured, call_adapter returns an error
no_adapter_test() ->
    %% Ensure no adapter is set
    application:unset_env(evoq, event_store_adapter),
    ?assertError({not_configured, event_store_adapter},
                 evoq_store_inspector:store_stats(test_store)).
