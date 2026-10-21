%% @doc Consistency modes for command dispatch.
%%
%% Supports:
%% - eventual: Return immediately after events are persisted
%% - strong: Wait for every event handler and projection subscribed to the
%%   appended events to have written them
%% - {handlers, [atom()]}: Wait for those handlers only
%%
%% Uses pg for handler acknowledgment tracking.
%%
%% == Strong Consistency Flow ==
%%
%% 1. The router OPENS a waiter for the stream, before the append
%%    (`open/2'): the caller's pid joins a pg group keyed by store and
%%    stream, so an ack can never arrive before anyone is listening.
%% 2. The command is dispatched and its events are appended.
%% 3. The router derives the required handlers from the appended events and
%%    the event type registry (`required/1'), which is the same lookup the
%%    event router delivers by.
%% 4. Each handler and projection calls `acknowledge/4' after its write,
%%    carrying the event's stream version.
%% 5. `await/4' returns when every required handler has acked a version at
%%    or past the one the dispatch produced, or `{error, timeout}'.
%%
%% Acks that arrive before the wait (a fast handler, an append that
%% delivered before the router got back) are in the caller's mailbox by the
%% time `await/4' runs, so they count. The version rides in the ack, so a
%% handler that was already past the stream answers for it, and one that is
%% behind does not.
%%
%% == What an ack says, and what a drop says ==
%%
%% An ack is sent only after the handler's own write. A handler whose error
%% policy dropped the event instead (`skip' or `{dead_letter, _}' from
%% `on_error/4') sends `dropped/2', and the wait answers
%% `{error, {dropped, Handler}}' at once, because that write will never
%% happen. A projection that deliberately skips an event it does not want
%% (`{skip, State, ReadModel}' from `project/4') is not a drop: it decided,
%% and it acks.
%%
%% A handler on another node is not in the required set. The registry is a
%% cluster-wide pg scope, so it names pids on every connected node, while the
%% router delivers only to local ones.
%%
%% Every waiter on a stream's group receives every ack for that stream, so
%% `close/1' takes the ones this wait did not consume out of the mailbox.
%%
%% == What strong does not wait for ==
%%
%% A process manager instance. Which instances handle an event is decided at
%% delivery time (`correlate/2', which may start one), so the set a caller
%% could wait for does not exist when it dispatches. A process manager that
%% needs its own writes seen dispatches and waits itself.
%%
%% == A handler that dispatches must not wait for its own event's handlers ==
%%
%% A cascade written as an `evoq_event_handler' (a module with
%% `interested_in/0', which the event type registry does hold, unlike a
%% process manager instance) is itself in the required set of the dispatch
%% that triggered it. Dispatching from its `handle_event/4' with `strong'
%% waits for the read models of the events it just appended, and the
%% projection that would ack them is still handling the event that ran the
%% cascade: it cannot pick up the new events until it returns, and the
%% cascade cannot return until they are acked. Both dispatches end at their
%% deadline with both writes made. A cascade dispatches `eventual': it does
%% not read its own write, and the entry-point dispatch that triggered it is
%% the one that asked for the guarantee.
%%
%% @author rgfaber
-module(evoq_consistency).

-include("evoq_telemetry.hrl").

%% API
-export([open/2, close/1, await/4]).
-export([required/2]).
-export([wait_for/4]).
-export([acknowledge/2, acknowledge/4, dropped/2]).
-export([waitable/1]).
-export([start_pg/0]).

-define(PG_SCOPE, evoq_consistency_pg).
-define(DEFAULT_TIMEOUT, 5000).

-type waiter() :: #{key := term(), store_id := atom(), stream_id := binary()}.
-export_type([waiter/0]).

%%====================================================================
%% API
%%====================================================================

%% @doc Start the pg scope for consistency tracking.
-spec start_pg() -> ok.
start_pg() ->
    case pg:start(?PG_SCOPE) of
        {ok, _Pid} -> ok;
        {error, {already_started, _Pid}} -> ok
    end.

%% @doc Open a waiter for one stream, before its command is appended.
%%
%% The calling process joins the pg group acks are published to, so an ack
%% for this stream reaches it whatever happens between the append and the
%% wait. Keyed by store and stream, never by version: the version is not
%% known until the append, and the ack carries its own.
-spec open(atom(), binary()) -> waiter().
open(StoreId, StreamId) ->
    start_pg(),
    Key = waiter_key(StoreId, StreamId),
    ok = pg:join(?PG_SCOPE, Key, self()),
    #{key => Key, store_id => StoreId, stream_id => StreamId}.

%% @doc Leave the group a waiter joined. Safe to call twice.
%%
%% Every waiter in a stream's group receives every ack for that stream, so a
%% caller that dispatches gets acks for handlers it never waited on, and a
%% concurrent dispatcher's ack can arrive here too. `await/4' takes out only
%% what it needs; the rest are taken out here, so a caller that dispatches in
%% a loop does not accumulate them in its mailbox. An ack already in flight
%% when the process leaves the group can still land after `close/1' has run:
%% a caller that keeps its mailbox clean against that uses a catch-all
%% `handle_info'.
-spec close(waiter()) -> ok.
close(#{key := Key, store_id := StoreId, stream_id := StreamId}) ->
    _ = pg:leave(?PG_SCOPE, Key, self()),
    flush(StoreId, StreamId).

%% @doc The handlers and projections subscribed to these appended events,
%% each with the LAST version of the append it is required for.
%%
%% Taken from the appended events and the event type registry, which is the
%% set the event router delivers to: no list is kept anywhere. An event type
%% no handler subscribes to contributes nothing, which is the truth.
%%
%% `FirstVersion' is the version the append's first event got, so the events
%% are handed `FirstVersion', `FirstVersion + 1', ... in the order they were
%% appended (the router derives it the same way when it computes the range).
%%
%% A handler answers for the version it was HANDED, not for the append's
%% last one: a handler subscribed to one of two appended events writes that
%% event and nothing else, so holding it to the second version is waiting for
%% a write it was never given, and every multi-event dispatch would end at
%% the deadline. A handler subscribed to both is required at the later one.
-spec required([map()], integer()) -> [{pid() | atom(), integer()}].
required(Events, FirstVersion) ->
    {Pairs, _Last} =
        lists:foldl(
          fun(Event, {Acc, Version}) ->
                  {[{Handler, Version} || Handler <- targets(Event)] ++ Acc, Version + 1}
          end, {[], FirstVersion}, Events),
    Wanted = lists:foldl(
               fun({Handler, Version}, M) ->
                       maps:put(Handler, max(Version, maps:get(Handler, M, 0)), M)
               end, #{}, Pairs),
    lists:sort(maps:to_list(Wanted)).

%% @private The pids the event router would notify for one event, from the
%% type it delivers it as (an upcaster can rename it). An appended event
%% still carries the type its aggregate wrote, which may be an atom; the
%% registry and the delivery both speak binaries.
targets(#{event_type := Type} = Event) when is_atom(Type) ->
    targets(Event#{event_type => atom_to_binary(Type, utf8)});
targets(Event) ->
    {_DeliveredAs, Handlers} = evoq_event_router:delivery_targets(Event),
    [H || H <- Handlers, waitable(H)].

%% @doc Is this registry entry one this node can wait for?
%%
%% The event type registry is a CLUSTER-WIDE pg scope, so `get_handlers/1'
%% names members of every connected node, while the router delivers only to
%% local pids and skips a remote one ("belongs to another node"). Waiting for
%% a remote pid is waiting for an ack that pid cannot send for this store: it
%% is not subscribed here and never sees the event, so every dispatch would
%% end in a consistency timeout. The required set is the delivered set, so a
%% pid on another node is not in it.
%%
%% An atom is not something the registry names: `register_handler/2' refuses a
%% module (`{error, not_supported}'), and the router's own module clause calls
%% `handle_event/4' without acknowledging anything. The clause answers true
%% because a module the registry cannot hold never reaches here, and a caller
%% that names one in `{handlers, ...}' is naming a handler with no process to
%% deliver to; refusing it here would be a different, larger change.
-spec waitable(pid() | atom()) -> boolean().
waitable(Pid) when is_pid(Pid) ->
    node(Pid) =:= node();
waitable(Module) when is_atom(Module) ->
    true.

%% @doc Wait until every required handler has acked the version IT was
%% required for.
%%
%% `Required' pairs each handler (a pid or a module) with the last version of
%% the append it was handed, as `required/2' answers for a derived set. Waits
%% for handlers and projections; a timeout answers as an error, never as a
%% silent success. An empty required list has nothing to wait for and answers
%% at once.
%%
%% An ack means the handler wrote its effect. A handler whose own error
%% policy dropped an event instead (`skip', `{dead_letter, _}' from
%% `on_error/4') says so with `dropped/2' rather than acknowledging, and this
%% answers `{error, {dropped, Handler}}' at once: the write did not happen,
%% and waiting out the deadline for it would say the same thing later and
%% less clearly.
%%
%% WHICH EVENTS ARE THIS DISPATCH'S is the append's own range of versions,
%% `{first_version, V}' in the options (the caller that appended knows it; it
%% is `Version' by default, the single event case). A drop is this call's
%% business only inside it: a stream carries every command's appends, so a
%% drop above it is the next command's (and a handler's messages arrive in
%% order, so it can only be one) and a drop below it was answered for before
%% this append began. Inside it, a drop fails the wait even when the same
%% handler went on to write a later version of the append, because that is
%% exactly the event the read model is missing.
-spec await(waiter(), [{pid() | atom(), integer()}], integer(), map()) ->
    ok | {error, timeout | {dropped, pid() | atom()}}.
await(Waiter, Required, Version, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    Range = {maps:get(first_version, Opts, Version), Version},
    wait_loop(Waiter, Required, #{}, Version, Range, Deadline).

%% @doc Acknowledge a handler's or projection's write from the event it was
%% handed.
%%
%% The routing metadata carries the store, the stream and the event's own
%% stream version, so a handler that just wrote needs nothing else. Metadata
%% without them (an event routed outside a store subscription) is not
%% acknowledged: there is no stream for a waiter to be waiting on.
-spec acknowledge(atom(), map()) -> ok.
acknowledge(Module, Metadata) ->
    Stores = {maps:get(store_id, Metadata, undefined),
              maps:get(stream_id, Metadata, undefined),
              maps:get(stream_version, Metadata, undefined)},
    acknowledge_written(Module, Stores).

%% @private
acknowledge_written(Module, {StoreId, StreamId, Version})
  when is_atom(StoreId), is_binary(StreamId), is_integer(Version) ->
    acknowledge(Module, StoreId, StreamId, Version);
acknowledge_written(_Module, _NotFromAStreamSubscription) ->
    ok.

%% @doc Acknowledge that a handler has processed an event.
%%
%% Called by the handler and projection processes themselves, after their
%% write, with the event's own stream version. `Module' and the calling pid
%% are both offered as identities, so a waiter can name either.
-spec acknowledge(atom(), atom(), binary(), integer()) -> ok.
acknowledge(Module, StoreId, StreamId, Version) ->
    notify_waiters({handler_ack, {self(), Module}, StoreId, StreamId, Version}).

%% @doc Say that a handler did NOT write this event: its own error policy
%% dropped it (`skip' or `{dead_letter, _}' from `on_error/4').
%%
%% The counterpart of `acknowledge/2'. It carries the same routing metadata
%% and is deliberately not an ack: a waiter told `ok' about an event a handler
%% dropped was told a write happened that did not.
-spec dropped(atom(), map()) -> ok.
dropped(Module, Metadata) ->
    Stores = {maps:get(store_id, Metadata, undefined),
              maps:get(stream_id, Metadata, undefined),
              maps:get(stream_version, Metadata, undefined)},
    dropped_written(Module, Stores).

%% @private
dropped_written(Module, {StoreId, StreamId, Version})
  when is_atom(StoreId), is_binary(StreamId), is_integer(Version) ->
    notify_waiters({handler_dropped, {self(), Module}, StoreId, StreamId, Version});
dropped_written(_Module, _NotFromAStreamSubscription) ->
    ok.

%% @private Every waiter listening on this stream hears it; one on another
%% stream never does.
notify_waiters(Message = {_Tag, _Identity, StoreId, StreamId, _Version}) ->
    start_pg(),
    Key = waiter_key(StoreId, StreamId),
    lists:foreach(fun(Pid) -> Pid ! Message end, pg:get_members(?PG_SCOPE, Key)),
    ok.

%% @doc Wait for exactly these handlers to ack this version.
%%
%% Kept for callers that name their handlers. `all' is REFUSED here rather
%% than answered at once: this function sees no events, so it cannot know
%% which handlers the dispatch would have to wait for, and `ok' would say
%% "they have all written" about a set it never looked up. A dispatch asks
%% for `strong' instead, which derives the set from the appended events.
%%
%% It sees no events, so it also does not know the append's range of versions:
%% only a drop of exactly `Version' fails this wait, and a drop of one of the
%% append's earlier versions is not noticed. A caller that appended several
%% events and wants the whole range calls `open/2' and `await/4' itself, with
%% `{first_version, V}'.
-spec wait_for(atom(), binary(), integer(), map()) -> ok | {error, timeout} | {error, all_needs_events}.
wait_for(StoreId, StreamId, Version, Opts) ->
    named(maps:get(handlers, Opts, all), StoreId, StreamId, Version, Opts).

%% @private
named(all, _StoreId, _StreamId, _Version, _Opts) ->
    {error, all_needs_events};
named(Handlers, StoreId, StreamId, Version, Opts) when is_list(Handlers) ->
    Waiter = open(StoreId, StreamId),
    try await(Waiter, [{Handler, Version} || Handler <- lists:usort(Handlers)], Version, Opts)
    after close(Waiter)
    end.

%%====================================================================
%% Internal functions
%%====================================================================

%% @private
waiter_key(StoreId, StreamId) ->
    {consistency_waiter, StoreId, StreamId}.

%% @private Nothing to wait for: every handler the router could reach has
%% been reached, because there is none.
wait_loop(_Waiter, [], _Acked, _Version, _Range, _Deadline) ->
    ok;

wait_loop(Waiter, Required, Acked, Version, Range, Deadline) ->
    acked_reply(all_acked(Required, Acked), Waiter, Required, Acked, Version,
                Range, Deadline).

%% @private
acked_reply(true, _Waiter, _Required, _Acked, _Version, _Range, _Deadline) ->
    ok;
acked_reply(false, #{store_id := StoreId, stream_id := StreamId} = Waiter,
            Required, Acked, Version, Range, Deadline) ->
    %% One deadline for the whole wait: an ack for another stream cannot
    %% reset it, and no unrelated message is taken out of the mailbox.
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {handler_ack, Identity, StoreId, StreamId, AckedVersion} when is_integer(AckedVersion) ->
            wait_loop(Waiter, Required, record(Identity, AckedVersion, Acked), Version,
                      Range, Deadline);
        {handler_dropped, Identity, StoreId, StreamId, DroppedVersion}
          when is_integer(DroppedVersion) ->
            drop_reply(Identity, DroppedVersion, Required, Waiter, Acked, Version,
                       Range, Deadline)
    after Remaining ->
        {error, timeout}
    end.

%% @private A handler this dispatch waits for dropped one of ITS events by its
%% own error policy, so that write will never happen: the answer is a drop, at
%% once, not a deadline. Anything else is another dispatch's and the wait
%% carries on: a drop by a handler this call does not wait for, one for an
%% event outside this append's range of versions, or one by a handler that has
%% already written the version this call waits for.
drop_reply({_Pid, _Module} = Identity, DroppedVersion, Required, Waiter, Acked, Version,
           Range, Deadline) ->
    Wanted = required_version(Identity, Required),
    ThisDispatch = Wanted =/= undefined,
    drop_verdict(ThisDispatch andalso in_range(DroppedVersion, Range)
                 andalso not satisfied(Identity, Acked, Wanted),
                 Identity, Required, Waiter, Acked, Version, Range, Deadline).

%% @private Named by its module: that is what a caller subscribes by, and it
%% is the same for the pid and the module identity of one handler.
drop_verdict(true, {_Pid, Module}, _Required, _Waiter, _Acked, _Version, _Range, _Deadline) ->
    {error, {dropped, Module}};
drop_verdict(false, _Identity, Required, Waiter, Acked, Version, Range, Deadline) ->
    wait_loop(Waiter, Required, Acked, Version, Range, Deadline).

%% @private The versions one command's append produced. Monotonic, so a drop
%% inside the range is one of this dispatch's events whatever order the
%% handlers' messages arrive in.
in_range(Version, {First, Last}) ->
    First =< Version andalso Version =< Last.

%% @private The version this handler is required for, by either identity;
%% `undefined' when this call does not wait for it at all.
required_version({Pid, Module}, Required) ->
    case [Version || {Handler, Version} <- Required, Handler =:= Pid orelse Handler =:= Module] of
        [] -> undefined;
        Versions -> lists:max(Versions)
    end.

%% @private Has this handler already written the version the call waits for it
%% to write? A handler's messages arrive in order, so this is the same test
%% `all_acked/2' makes, asked of one handler.
satisfied({Pid, Module}, Acked, Wanted) ->
    max(maps:get(Pid, Acked, -1), maps:get(Module, Acked, -1)) >= Wanted.

%% @private Take this stream's acks and drops out of the mailbox, after
%% leaving the group. `after 0', so an empty mailbox costs nothing.
flush(StoreId, StreamId) ->
    receive
        {handler_ack, _Identity, StoreId, StreamId, _Version} ->
            flush(StoreId, StreamId);
        {handler_dropped, _Identity, StoreId, StreamId, _Version} ->
            flush(StoreId, StreamId)
    after 0 ->
        ok
    end.

%% @private Both identities of the acking process, so a required entry
%% matches whether it names the pid or the module.
record({Pid, Module}, Version, Acked) ->
    Higher = fun(Key) -> max(maps:get(Key, Acked, -1), Version) end,
    Acked#{Pid => Higher(Pid), Module => Higher(Module)}.

%% @private A handler counts when its own ack is at or past the version it is
%% required for: one already ahead of that has written it, one behind has not.
%% Two handlers of one append are answered against their own versions, never
%% against the append's last one (evoq#23's multi-event defect).
all_acked(Required, Acked) ->
    lists:all(fun({Handler, Version}) -> maps:get(Handler, Acked, -1) >= Version end, Required).
