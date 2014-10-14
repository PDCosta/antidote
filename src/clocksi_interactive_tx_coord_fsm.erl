%% -------------------------------------------------------------------
%%
%% Copyright (c) 2014 SyncFree Consortium.  All Rights Reserved.
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License.  You may obtain
%% a copy of the License at
%%
%%   http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied.  See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%% @doc The coordinator for a given Clock SI interactive transaction.
%%      It handles the state of the tx and executes the operations sequentially
%%      by sending each operation to the responsible clockSI_vnode of the
%%      involved key. when a tx is finalized (committed or aborted, the fsm
%%      also finishes.

-module(clocksi_interactive_tx_coord_fsm).

-behavior(gen_fsm).

-include("floppy.hrl").

%% API
-export([start_link/2, start_link/1]).

%% Callbacks
-export([init/1, code_change/4, handle_event/3, handle_info/3,
         handle_sync_event/4, terminate/3]).

%% States
-export([execute_op/3, finish_op/3, prepare/2,
         receive_prepared/2, committing/3, receive_committed/2, abort/2,
         reply_to_client/2]).

%%---------------------------------------------------------------------
%% @doc Data Type: state
%% where:
%%    from: the pid of the calling process.
%%    txid: transaction id handled by this fsm, as defined in src/floppy.hrl.
%%    updated_partitions: the partitions where update operations take place.
%%    num_to_ack: when sending prepare_commit,
%%                number of partitions that have acked.
%%    prepare_time: transaction prepare time.
%%    commit_time: transaction commit time.
%%    state: state of the transaction: {active|prepared|committing|committed}
%%----------------------------------------------------------------------
-record(state, {
          from,
          transaction :: #transaction{},
          updated_partitions :: list(),
          num_to_ack :: integer(),
          prepare_time :: integer(),
          commit_time :: integer(),
          state:: atom()}).

%%%===================================================================
%%% API
%%%===================================================================

start_link(From, Clientclock) ->
    gen_fsm:start_link(?MODULE, [From, Clientclock], []).

start_link(From) ->
    gen_fsm:start_link(?MODULE, [From, ignore], []).

finish_op(From, Key,Result) ->
    gen_fsm:send_event(From, {Key, Result}).

%%%===================================================================
%%% States
%%%===================================================================

%% @doc Initialize the state.
init([From, Clientclock]) ->
    case Clientclock of
        ignore -> {ok, Snapshot_time} = get_snapshot_time();
        _ -> {ok, Snapshot_time}= get_snapshot_time(Clientclock)
    end,
    TxId=#tx_id{snapshot_time=Snapshot_time, server_pid=self()},
    {ok, Vec_clock} = vectorclock:get_clock_node(node()),
    Dc_id = dc_utilities:get_my_dc_id(),
    Vec_snapshot_time = dict:update(Dc_id,
                                    fun (_Old) -> Snapshot_time end,
                                    Snapshot_time,
                                    Vec_clock),
    Transaction = #transaction{snapshot_time = Snapshot_time,
                               vec_snapshot_time = Vec_snapshot_time,
                               txn_id = TxId},
    SD = #state{
            transaction = Transaction,
            updated_partitions=[],
            prepare_time=0
           },
    From ! {ok, TxId},
    {ok, execute_op, SD}.

%% @doc Contact the leader computed in the prepare state for it to execute the
%%      operation, wait for it to finish (synchronous) and go to the prepareOP
%%       to execute the next operation.
execute_op({Op_type, Args}, Sender,
           SD0=#state{transaction=Transaction, from=From,
                      updated_partitions=Updated_partitions}) ->
    case Op_type of
        prepare ->
            lager:info("ClockSI-Interactive-Coord: Sender ~w ~n ", [Sender]),
            {next_state, prepare, SD0#state{from=Sender}, 0};
        read ->
            {Key, Type}=Args,
            lager:info("ClockSI-Interactive-Coord: PID ~w ~n ", [self()]),
            lager:info("ClockSI-Interactive-Coord: Op ~w ~n ", [Args]),
            lager:info("ClockSI-Interactive-Coord: Sender ~w ~n ", [Sender]),
            lager:info("ClockSI-Interactive-Coord: getting leader for Key ~w",
                       [Key]),
            Preflist = log_utilities:get_preflist_from_key(Key),
            IndexNode = hd(Preflist),
            case clocksi_vnode:read_data_item(IndexNode, Transaction,
                                              Key, Type) of
                error ->
                    {reply, error, abort, SD0};
                {error, _Reason} ->
                    {next_state, abort, SD0};
                {ok, Snapshot} ->
                    ReadResult = Type:value(Snapshot),
                    lager:info("ClockSI-Interactive-Coord: Read Result:  ~w ~n",
                               [ReadResult]),
                    {reply, {ok, ReadResult}, execute_op, SD0}
            end;
        update ->
            {Key, Type, Param}=Args,
            lager:info("ClockSI-Interactive-Coord: PID ~w ~n ", [self()]),
            lager:info("ClockSI-Interactive-Coord: Op ~w ~n ", [Args]),
            lager:info("ClockSI-Interactive-Coord: Sender ~w ~n ", [Sender]),
            lager:info("ClockSI-Interactive-Coord: From ~w ~n ", [From]),
            lager:info("ClockSI-Interactive-Coord: getting leader for Key ~w ",
                       [Key]),
            Preflist = log_utilities:get_preflist_from_key(Key),
            IndexNode = hd(Preflist),
            case generate_downstream_op(Transaction, IndexNode, Key, Type, Param) of
                {ok, DownstreamRecord} ->
                    case clocksi_vnode:update_data_item(IndexNode, Transaction,
                                                Key, Type, Param, DownstreamRecord) of
                        ok ->
                            case lists:member(IndexNode, Updated_partitions) of
                                false ->
                                    New_updated_partitions=
                                        lists:append(Updated_partitions, [IndexNode]),
                                    {reply, ok, execute_op,
                                    SD0#state
                                    {updated_partitions= New_updated_partitions}};
                                true->
                                    {reply, ok, execute_op, SD0}
                            end;
                        error ->
                            {reply, error, abort, SD0}
                    end;
                {error, _} ->
                    {reply, error, abort, SD0}
            end
    end.


%% @doc a message from a client wanting to start committing the tx.
%%      this state sends a prepare message to all updated partitions and goes
%%      to the "receive_prepared"state.
prepare(timeout, SD0=#state{
                        transaction = Transaction,
                        updated_partitions=Updated_partitions, from=From}) ->
    case length(Updated_partitions) of
        0->
            Snapshot_time=Transaction#transaction.snapshot_time,
            gen_fsm:reply(From, {ok, Snapshot_time}),
            {next_state, committing,
             SD0#state{state=committing, commit_time=Snapshot_time}};
        _->
            clocksi_vnode:prepare(Updated_partitions, Transaction),
            Num_to_ack=length(Updated_partitions),
            {next_state, receive_prepared,
             SD0#state{num_to_ack=Num_to_ack, state=prepared}}
    end.

%% @doc in this state, the fsm waits for prepare_time from each updated
%%      partitions in order to compute the final tx timestamp (the maximum
%%      of the received prepare_time).
receive_prepared({prepared, ReceivedPrepareTime},
                 S0=#state{num_to_ack= NumToAck,
                           from= From, prepare_time=PrepareTime}) ->
    MaxPrepareTime = max(PrepareTime, ReceivedPrepareTime),
    case NumToAck of 1 ->
            lager:info("ClockSI: Commiting at Commit time: ~p",
                       [MaxPrepareTime]),
            gen_fsm:reply(From, {ok, MaxPrepareTime}),
            {next_state, committing,
             S0#state{prepare_time=MaxPrepareTime,
                      commit_time=MaxPrepareTime, state=committing}};
        _ ->
            lager:info("ClockSI: Keep collecting prepare replies."),
            {next_state, receive_prepared,
             S0#state{num_to_ack= NumToAck-1, prepare_time=MaxPrepareTime}}
    end;

receive_prepared(abort, S0) ->
    lager:info("ClockSI: Got reply to abort."),
    {next_state, abort, S0, 0};

receive_prepared(timeout, S0) ->
    lager:info("ClockSI: Did not receive all replies in time, aborting..."),
    {next_state, abort, S0 ,0}.

%% @doc after receiving all prepare_times, send the commit message to all
%%       updated partitions, and go to the "receive_committed" state.
committing(commit, Sender, SD0=#state{transaction = Transaction,
                                      updated_partitions=Updated_partitions,
                                      commit_time=Commit_time}) ->
    NumToAck=length(Updated_partitions),
    case NumToAck of
        0 ->
            {next_state, reply_to_client,
             SD0#state{state=committed, from=Sender},0};
        _ ->
            clocksi_vnode:commit(Updated_partitions, Transaction, Commit_time),
            {next_state, receive_committed,
             SD0#state{num_to_ack=NumToAck, from=Sender, state=committing}}
    end.


%% @doc the fsm waits for acks indicating that each partition has successfully
%%	committed the tx and finishes operation.
%%      Should we retry sending the committed message if we don't receive a
%%      reply from every partition?
%%      What delivery guarantees does sending messages provide?
receive_committed(committed, S0=#state{num_to_ack= NumToAck}) ->
    case NumToAck of
        1 ->
            lager:info("ClockSI: Finished collecting commit acks. Tx committed succesfully.~n"),
            {next_state, reply_to_client, S0#state{state=committed}, 0};
        _ ->
            lager:info("ClockSI: Keep collecting commit replies~n"),
            {next_state, receive_committed, S0#state{num_to_ack= NumToAck-1}}
    end.

%% @doc when an updated partition does not pass the certification check,
%%      the transaction aborts.
abort(timeout, SD0=#state{transaction = Transaction,
                          updated_partitions=UpdatedPartitions}) ->
    lager:info("ClockSI-coord-fsm: aborting..."),
    clocksi_vnode:abort(UpdatedPartitions, Transaction),
    lager:info("ClockSI-coord-fsm: sent abort command to partitions..."),
    {next_state, reply_to_client, SD0#state{state=aborted},0};

abort(abort, SD0=#state{transaction = Transaction,
                        updated_partitions=UpdatedPartitions}) ->
    lager:info("ClockSI-coord-fsm: received abort command, aborting..."),
    clocksi_vnode:abort(UpdatedPartitions, Transaction),
    lager:info("ClockSI-coord-fsm: sent abort command to partitions..."),
    {next_state, reply_to_client, SD0#state{state=aborted},0}.

%% @doc when the transaction has committed or aborted,
%%       a reply is sent to the client that started the transaction.
reply_to_client(timeout, SD=#state{from=From, transaction=Transaction,
                                   state=TxState, commit_time=CommitTime}) ->
    lager:info("ClockSI-coord-fsm: Replying ~w to ~w", [TxState, From]),
    TxId = Transaction#transaction.txn_id,
    case TxState of
        committed->
            Reply={ok, {TxId, CommitTime}},
            gen_fsm:reply(From,Reply);
        aborted->
            gen_fsm:reply(From,{aborted, TxId});
        Reason->
            gen_fsm:reply(From,{TxId, Reason})
    end,
    {stop, normal, SD}.



%% =============================================================================

handle_info(_Info, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_event(_Event, _StateName, StateData) ->
    {stop,badmsg,StateData}.

handle_sync_event(_Event, _From, _StateName, StateData) ->
    {stop,badmsg,StateData}.

code_change(_OldVsn, StateName, State, _Extra) -> {ok, StateName, State}.

terminate(_Reason, _SN, _SD) ->
    ok.

%%%===================================================================
%%% Internal Functions
%%%===================================================================

%%@doc Set the transaction Snapshot Time to the maximum value of:
%%     1.ClientClock, which is the last clock of the system the client
%%       starting this transaction has seen, and
%%     2.machine's local time, as returned by erlang:now().
-spec get_snapshot_time(ClientClock :: non_neg_integer()) ->
                               {ok, non_neg_integer()}.
get_snapshot_time(ClientClock) ->
    Now=clocksi_vnode: now_milisec(erlang:now()),
    case (ClientClock > Now) of
        true->
            SnapshotTime = ClientClock + ?MIN;
        false ->
            SnapshotTime = Now
    end,
    {ok, SnapshotTime}.

-spec get_snapshot_time() -> {ok, non_neg_integer()}.
get_snapshot_time() ->
    Now = clocksi_vnode:now_milisec(erlang:now()),
    Snapshot_time  = Now - ?DELTA,
    {ok, Snapshot_time}.

-spec generate_downstream_op(#transaction{}, index_node(), key(), type(), op()) 
                            -> {ok, #clocksi_payload{}} | {error, atom()}.
generate_downstream_op(Txn, IndexNode, Key, Type, Param) ->
    TxnId = Txn#transaction.txn_id,
    Snapshot_time=Txn#transaction.vec_snapshot_time,
    Record = #clocksi_payload{key = Key, type = Type,
                                op_param = Param,
                                snapshot_time = Snapshot_time,
                                txid = TxnId},
    clocksi_downstream:generate_downstream_op(Txn, IndexNode, Record).
