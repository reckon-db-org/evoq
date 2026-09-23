%% @doc Clears evoq processes other test modules left running.
%%
%% Most modules in this suite start the evoq processes they need when
%% missing and leave them running. A module that must own them (a full
%% `application:ensure_all_started(evoq)', or a simulated node restart)
%% cannot start them while those are registered. gen_server:stop/1 exits
%% `normal', so nothing linked to them dies, and the modules that left them
%% start them again when they next need them.
-module(evoq_test_isolation).

-export([stop_leftover_evoq/0]).

stop_leftover_evoq() ->
    _ = application:stop(evoq),
    lists:foreach(fun stop_registered/1,
                  [evoq_pm_instance_sup, evoq_pm_router, evoq_event_router,
                   evoq_type_provider, evoq_event_type_registry]).

stop_registered(Name) ->
    stop_if_running(whereis(Name)).

stop_if_running(undefined) -> ok;
stop_if_running(Pid) -> catch gen_server:stop(Pid), ok.
