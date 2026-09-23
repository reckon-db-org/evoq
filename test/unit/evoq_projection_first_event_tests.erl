%% @doc A projection must project the FIRST event it is ever handed.
%%
%% evoq_store_subscription numbers the events it routes from 0 and hands
%% that number to every projection as metadata `version'. A projection
%% skips any event whose version is not above its checkpoint, so a
%% checkpoint that means "nothing processed yet" must sit BELOW 0. It
%% did not when a checkpoint store was configured but held nothing yet:
%% `load/1' returning `{error, not_found}' (every projection's first
%% boot) or a store not exporting `load/1' at all both became 0, and
%% event 0 was dropped without a word.
%%
%% This module is its own projection and its own checkpoint store, so
%% each test decides exactly what the store answers.
-module(evoq_projection_first_event_tests).

-behaviour(evoq_projection).

-include_lib("eunit/include/eunit.hrl").

-export([interested_in/0, init/1, project/4]).
-export([load/1, save/2]).

-define(TYPE, <<"first_event_probe_v1">>).

%%====================================================================
%% Tests
%%====================================================================

first_event_is_projected_when_the_store_has_no_checkpoint_yet_test() ->
    ensure_registry(),
    set_stored(not_found),
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{},
                                           #{checkpoint_store => ?MODULE}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual([1], projected(Pid)),
    stop(Pid).

a_stored_checkpoint_still_skips_what_it_already_covers_test() ->
    ensure_registry(),
    set_stored({ok, 0}),
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{},
                                           #{checkpoint_store => ?MODULE}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(2), #{version => 1}),
    ?assertEqual([2], projected(Pid)),
    stop(Pid).

%% A module that exports neither load/1 nor save/2 stands in for a store
%% that cannot load: `lists' is always loaded and has neither.
first_event_is_projected_when_the_store_cannot_load_test() ->
    ensure_registry(),
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{},
                                           #{checkpoint_store => lists}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual([1], projected(Pid)),
    stop(Pid).

first_event_is_projected_without_a_checkpoint_store_test() ->
    ensure_registry(),
    {ok, Pid} = evoq_projection:start_link(?MODULE, #{}, #{}),
    ok = evoq_projection:notify(Pid, ?TYPE, event(1), #{version => 0}),
    ?assertEqual([1], projected(Pid)),
    stop(Pid).

%%====================================================================
%% evoq_projection callbacks
%%====================================================================

interested_in() -> [?TYPE].

init(_Config) ->
    {ok, RM} = evoq_read_model:new(evoq_read_model_ets, #{}),
    {ok, [], RM}.

project(#{data := #{n := N}}, _Metadata, Seen, RM) ->
    {ok, Seen ++ [N], RM}.

%%====================================================================
%% evoq_checkpoint_store callbacks
%%====================================================================

load(_ProjectionName) ->
    persistent_term:get({?MODULE, stored}, {error, not_found}).

save(_ProjectionName, _Checkpoint) ->
    ok.

%%====================================================================
%% Helpers
%%====================================================================

set_stored(not_found) -> persistent_term:put({?MODULE, stored}, {error, not_found});
set_stored(Answer) -> persistent_term:put({?MODULE, stored}, Answer).

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
