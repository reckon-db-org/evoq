%% @doc A checkpoint must not outlive the read model it describes (evoq #1).
%%
%% A projection skips every event at or below its checkpoint as already
%% projected. A checkpoint store keeps that number across a restart; an
%% in-memory read model does not keep the data. Paired, a restart loads
%% "everything up to N is projected" next to an empty read model, skips the
%% whole history, and serves nothing, silently. evoq_read_model_ets is owned
%% by the projection process, so even evoq_checkpoint_store_ets (node-wide)
%% outlives it: a projection crash alone is enough.
%%
%% So a projection whose read model does not declare itself durable refuses a
%% checkpoint store at start.
-module(evoq_projection_durable_read_model_tests).

-behaviour(evoq_projection).

-include_lib("eunit/include/eunit.hrl").

-export([interested_in/0, init/1, project/4]).

-define(TYPE, <<"durable_probe_v1">>).

%% The failure itself, end to end: a projection on an in-memory read model
%% with a checkpoint store that survives restarts projects two events, is
%% restarted, and comes back with the checkpoint and an empty read model.
%% Refused at start, it never gets there.
an_in_memory_read_model_refuses_a_checkpoint_store_test() ->
    ensure_registry(),
    ok = evoq_restart_probe_checkpoint_store:reset(),
    process_flag(trap_exit, true),
    try
        ?assertEqual({error, {checkpoint_outlives_read_model, ?MODULE, evoq_read_model_ets}},
                     evoq_projection:start_link(
                       ?MODULE, #{read_model => evoq_read_model_ets},
                       #{checkpoint_store => evoq_restart_probe_checkpoint_store}))
    after
        process_flag(trap_exit, false)
    end.

%% A node-wide checkpoint store is refused too: the ETS read model dies with
%% the projection process, the ETS checkpoint store does not.
an_in_memory_read_model_refuses_the_ets_checkpoint_store_test() ->
    ensure_registry(),
    {ok, Store} = evoq_checkpoint_store_ets:start_link(),
    process_flag(trap_exit, true),
    try
        ?assertMatch({error, {checkpoint_outlives_read_model, ?MODULE, _}},
                     evoq_projection:start_link(
                       ?MODULE, #{read_model => evoq_read_model_ets},
                       #{checkpoint_store => evoq_checkpoint_store_ets}))
    after
        process_flag(trap_exit, false),
        stop(Store)
    end.

%% A read model that says nothing about durability is not assumed durable:
%% the refusal is cheap to answer (export durable/0), the silent loss is not.
a_read_model_without_durable_is_refused_a_checkpoint_store_test() ->
    ensure_registry(),
    process_flag(trap_exit, true),
    try
        ?assertMatch({error, {checkpoint_outlives_read_model, ?MODULE, _}},
                     evoq_projection:start_link(
                       ?MODULE, #{read_model => evoq_silent_probe_read_model},
                       #{checkpoint_store => evoq_restart_probe_checkpoint_store}))
    after
        process_flag(trap_exit, false)
    end.

%% A durable read model keeps its checkpoint store, and resumes from it.
a_durable_read_model_keeps_its_checkpoint_store_test() ->
    ensure_registry(),
    ok = evoq_restart_probe_checkpoint_store:reset(),
    {ok, Pid} = evoq_projection:start_link(
                  ?MODULE, #{read_model => evoq_durable_probe_read_model},
                  #{checkpoint_store => evoq_restart_probe_checkpoint_store}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
    stop(Pid).

%% An in-memory read model without a checkpoint store is the ordinary,
%% supported shape: it starts from nothing every time.
an_in_memory_read_model_without_a_checkpoint_store_starts_test() ->
    ensure_registry(),
    {ok, Pid} = evoq_projection:start_link(
                  ?MODULE, #{read_model => evoq_read_model_ets}, #{}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual(0, evoq_projection:get_checkpoint(Pid)),
    stop(Pid).

%% The ETS read model says what it is.
the_ets_read_model_is_not_durable_test() ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    ?assertNot(evoq_read_model:durable(RM)).

%%====================================================================
%% evoq_projection callbacks
%%====================================================================

interested_in() -> [?TYPE].

init(#{read_model := Module}) ->
    {ok, RM} = evoq_read_model:new(Module, #{name => ?MODULE}),
    {ok, #{}, RM}.

project(_Event, _Metadata, State, RM) ->
    {ok, State, RM}.

%%====================================================================
%% Helpers
%%====================================================================

event(N) -> #{event_type => ?TYPE, data => #{n => N}}.

ensure_registry() ->
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link(), ok;
        _ -> ok
    end.

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid).
