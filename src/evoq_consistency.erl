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
%% @author rgfaber
-module(evoq_consistency).

-include("evoq_telemetry.hrl").

%% API
-export([open/2, close/1, await/4]).
-export([required/1]).
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

%% @doc The handlers and projections subscribed to the types of these events.
%%
%% Taken from the appended events and the event type registry, which is the
%% set the event router delivers to: no list is kept anywhere. An event type
%% no handler subscribes to contributes nothing, which is the truth.
-spec required([map()]) -> [pid()].
required(Events) ->
    lists:usort(lists:flatmap(fun targets/1, Events)).

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
%% pid on another node is not in it. A module entry stays: the router calls
%% it here, and it acks through the calling process.
-spec waitable(pid() | atom()) -> boolean().
waitable(Pid) when is_pid(Pid) ->
    node(Pid) =:= node();
waitable(Module) when is_atom(Module) ->
    true.

%% @doc Wait until every required handler has acked the given stream version.
%%
%% Waits for handlers and projections; a timeout answers as an error, never
%% as a silent success. An empty required list has nothing to wait for and
%% answers at once.
%%
%% An ack means the handler wrote its effect. A handler whose own error
%% policy dropped an event instead (`skip', `{dead_letter, _}' from
%% `on_error/4') says so with `dropped/2' rather than acknowledging, and this
%% answers `{error, {dropped, Handler}}' at once: the write did not happen,
%% and waiting out the deadline for it would say the same thing later and
%% less clearly.
-spec await(waiter(), [pid() | atom()], integer(), map()) ->
    ok | {error, timeout | {dropped, pid() | atom()}}.
await(Waiter, Required, Version, Opts) ->
    Timeout = maps:get(timeout, Opts, ?DEFAULT_TIMEOUT),
    Deadline = erlang:monotonic_time(millisecond) + Timeout,
    wait_loop(Waiter, lists:usort(Required), #{}, Version, Deadline).

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
-spec wait_for(atom(), binary(), integer(), map()) -> ok | {error, timeout} | {error, all_needs_events}.
wait_for(StoreId, StreamId, Version, Opts) ->
    named(maps:get(handlers, Opts, all), StoreId, StreamId, Version, Opts).

%% @private
named(all, _StoreId, _StreamId, _Version, _Opts) ->
    {error, all_needs_events};
named(Handlers, StoreId, StreamId, Version, Opts) when is_list(Handlers) ->
    Waiter = open(StoreId, StreamId),
    try await(Waiter, Handlers, Version, Opts)
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
wait_loop(_Waiter, [], _Acked, _Version, _Deadline) ->
    ok;

wait_loop(Waiter, Required, Acked, Version, Deadline) ->
    acked_reply(all_acked(Required, Acked, Version), Waiter, Required, Acked, Version, Deadline).

%% @private
acked_reply(true, _Waiter, _Required, _Acked, _Version, _Deadline) ->
    ok;
acked_reply(false, #{store_id := StoreId, stream_id := StreamId} = Waiter,
            Required, Acked, Version, Deadline) ->
    %% One deadline for the whole wait: an ack for another stream cannot
    %% reset it, and no unrelated message is taken out of the mailbox.
    Remaining = max(0, Deadline - erlang:monotonic_time(millisecond)),
    receive
        {handler_ack, Identity, StoreId, StreamId, AckedVersion} when is_integer(AckedVersion) ->
            wait_loop(Waiter, Required, record(Identity, AckedVersion, Acked), Version, Deadline);
        {handler_dropped, Identity, StoreId, StreamId, DroppedVersion}
          when is_integer(DroppedVersion) ->
            drop_reply(Identity, DroppedVersion, Required, Waiter, Acked, Version, Deadline)
    after Remaining ->
        {error, timeout}
    end.

%% @private A handler this dispatch waits for dropped the event by its own
%% error policy, so it will never ack: the answer is a drop, at once, not a
%% deadline. A drop for a handler this dispatch does not wait for, or for an
%% event below the one being waited on, is about some other dispatch and the
%% wait carries on.
drop_reply({Pid, Module} = Identity, DroppedVersion, Required, Waiter, Acked, Version, Deadline) ->
    WaitedFor = lists:member(Pid, Required) orelse lists:member(Module, Required),
    drop_verdict(WaitedFor andalso DroppedVersion >= Version,
                 Identity, Required, Waiter, Acked, Version, Deadline).

%% @private Named by its module: that is what a caller subscribes by, and it
%% is the same for the pid and the module identity of one handler.
drop_verdict(true, {_Pid, Module}, _Required, _Waiter, _Acked, _Version, _Deadline) ->
    {error, {dropped, Module}};
drop_verdict(false, _Identity, Required, Waiter, Acked, Version, Deadline) ->
    wait_loop(Waiter, Required, Acked, Version, Deadline).

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

%% @private A handler counts for the required version when its own ack is at
%% or past it: one already ahead of the stream has written it, one behind
%% has not.
all_acked(Required, Acked, Version) ->
    lists:all(fun(Handler) -> maps:get(Handler, Acked, -1) >= Version end, Required).
