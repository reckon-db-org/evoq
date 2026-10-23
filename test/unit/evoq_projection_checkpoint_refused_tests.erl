%% @doc A checkpoint the store refuses is visible, not folded into "no
%% checkpoint" (reckon-db#25).
%%
%% On a store with integrity on, a planted, raised or unsealed checkpoint
%% loads as `{error, {integrity_violation, _}}'. The projection read every
%% `{error, _}' as -1, the same answer as a first boot, and rebuilt from the
%% start without a line: a tampered checkpoint looked like a fresh one, and
%% a read model that is not idempotent applied every event twice.
%%
%% It still rebuilds from the start (the refused position is not trusted),
%% and now says so: `evoq_projection_checkpoint_refused' is logged and
%% `[evoq, projection, checkpoint_refused]' emitted, with `kind => integrity'
%% for an integrity refusal and `kind => store' for any other store error.
%% `{error, not_found}' is a first boot and stays silent.
%%
%% This module is its own projection, its own checkpoint store and its own
%% logger handler, so each test decides exactly what the store answers.
-module(evoq_projection_checkpoint_refused_tests).

-behaviour(evoq_projection).

-include_lib("eunit/include/eunit.hrl").
-include("evoq_telemetry.hrl").

-export([interested_in/0, init/1, project/4]).
-export([load/1, save/2]).
-export([log/2]).

-define(TYPE, <<"checkpoint_refused_probe_v1">>).

%%====================================================================
%% Tests
%%====================================================================

an_integrity_refusal_is_logged_and_emitted_test() ->
    Reason = {integrity_violation, #{layer => snapshot, reason => signature_mismatch}},
    {Emitted, Logged, Pid} = boot_with({error, Reason}),
    ?assertMatch([#{kind := integrity, projection := ?MODULE, reason := Reason}], Emitted),
    ?assertMatch([#{what := evoq_projection_checkpoint_refused, kind := integrity}], Logged),
    %% The refused position is not trusted: the projection starts from the
    %% beginning and projects the first event.
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual([1], projected(Pid)),
    stop(Pid).

any_other_store_error_is_logged_and_emitted_as_a_store_refusal_test() ->
    {Emitted, Logged, Pid} = boot_with({error, timeout}),
    ?assertMatch([#{kind := store, projection := ?MODULE, reason := timeout}], Emitted),
    ?assertMatch([#{what := evoq_projection_checkpoint_refused, kind := store}], Logged),
    stop(Pid).

%% A first boot is not a refusal: nothing is logged or emitted, so the two
%% tests above cannot pass on a projection that reports every load.
a_first_boot_reports_nothing_test() ->
    {Emitted, Logged, Pid} = boot_with({error, not_found}),
    ?assertEqual([], Emitted),
    ?assertEqual([], Logged),
    stop(Pid).

%%====================================================================
%% evoq_projection callbacks
%%====================================================================

interested_in() -> [?TYPE].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_durable_probe_read_model, #{name => ?MODULE}),
    {ok, [], RM}.

project(#{data := #{n := N}}, _Metadata, Seen, RM) ->
    {ok, Seen ++ [N], RM}.

%%====================================================================
%% evoq_checkpoint_store callbacks
%%====================================================================

load(_ProjectionName) ->
    persistent_term:get({?MODULE, stored}).

save(_ProjectionName, _Checkpoint) ->
    ok.

%%====================================================================
%% logger handler callback: forwards this projection's refusal reports
%%====================================================================

log(#{msg := {report, #{what := evoq_projection_checkpoint_refused} = Report}},
    #{config := #{test := Test}}) ->
    Test ! {logged, Report};
log(_Event, _Config) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

%% Start the projection with the store answering Answer, and collect what
%% its boot logged and emitted. The handlers are attached here, in the
%% test's own process, and run in the projection's.
boot_with(Answer) ->
    {ok, _} = application:ensure_all_started(telemetry),
    ensure_registry(),
    persistent_term:put({?MODULE, stored}, Answer),
    Self = self(),
    HandlerId = {?MODULE, Self},
    ok = telemetry:attach(HandlerId, ?TELEMETRY_PROJECTION_CHECKPOINT_REFUSED,
                          fun(_Event, _Measurements, Meta, _Config) ->
                              Self ! {emitted, Meta}
                          end, undefined),
    ok = logger:add_handler(?MODULE, ?MODULE, #{config => #{test => Self}}),
    try
        {ok, Pid} = evoq_projection:start_link(?MODULE, #{},
                                               #{checkpoint_store => ?MODULE}),
        _ = sys:get_state(Pid),
        {collect(emitted), collect(logged), Pid}
    after
        telemetry:detach(HandlerId),
        logger:remove_handler(?MODULE)
    end.

collect(Tag) ->
    receive
        {Tag, Item} -> [Item | collect(Tag)]
    after 100 ->
        []
    end.

event(N) -> #{event_type => ?TYPE, data => #{n => N}}.

%% The projection's own state is the list of what it projected, in order.
projected(Pid) ->
    element(3, sys:get_state(Pid)).

ensure_registry() ->
    case whereis(evoq_event_type_registry) of
        undefined -> {ok, _} = evoq_event_type_registry:start_link(), ok;
        _ -> ok
    end.

stop(Pid) ->
    unlink(Pid),
    gen_server:stop(Pid).
