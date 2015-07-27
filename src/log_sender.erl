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
-module(log_sender).
-behaviour(riak_core_vnode).

%% Each logging_vnode informs this vnode about every new appended operation.
%% This vnode assembles operations into transactions, and sends the transactions to appropriate destinations.
%% If no transaction is sent in 10 seconds, heartbeat messages are sent instead.

-include("antidote.hrl").
-include("inter_dc_repl.hrl").
-include_lib("riak_core/include/riak_core_vnode.hrl").
-export([start_vnode/1, send/2, handle_info/2]).
-export([init/1, handle_command/3, handle_coverage/4, handle_exit/3, handoff_starting/2, handoff_cancelled/1, handoff_finished/2, handle_handoff_command/3, handle_handoff_data/2, encode_handoff_item/2, is_empty/1, terminate/2, delete/1]).

-record(state, {
  partition :: partition_id(),
  buffer, %% log_tx_assembler:state
  last_log_id :: non_neg_integer(),
  ping_timer :: any()
}).

%% API
start_vnode(I) -> riak_core_vnode_master:get_vnode_pid(I, ?MODULE).
send(Partition, Operation) -> dc_utilities:call_vnode_sync(Partition, log_sender_master, {log_event, Operation}).

init([Partition]) ->
  {ok, #state{
    partition = Partition,
    buffer = log_txn_assembler:new_state(),
    last_log_id = 0,
    ping_timer = timer()
  }}.

handle_command({log_event, Operation}, _Sender, State) ->
  {Result, NewBufState} = log_txn_assembler:process(Operation, State#state.buffer),
  NewState = State#state{buffer = NewBufState},
  case Result of
    {ok, Ops} -> {reply, ok, broadcast(NewState, #interdc_txn{
      dcid = dc_utilities:get_my_dc_id(),
      partition = State#state.partition,
      logid_range = new_inter_dc_utils:logid_range(Ops),
      operations = Ops,
      snapshot = new_inter_dc_utils:snapshot(Ops),
      timestamp = new_inter_dc_utils:commit_time(Ops)
    })};
    none -> {reply, ok, NewState}
  end.

handle_info(timeout, State) ->
  {ok, broadcast(State, #interdc_txn{
    dcid = dc_utilities:get_my_dc_id(),
    partition = State#state.partition,
    logid_range = {State#state.last_log_id, State#state.last_log_id},
    operations = [],
    snapshot = dict:new(),
    timestamp = new_inter_dc_utils:now_millisec() %% TODO: think if this can cause any problems
  })}.

handle_coverage(_Req, _KeySpaces, _Sender, State) -> {stop, not_implemented, State}.
handle_exit(_Pid, _Reason, State) -> {noreply, State}.
handoff_starting(_TargetNode, State) -> {true, State}.
handoff_cancelled(State) -> {ok, State}.
handoff_finished(_TargetNode, State) -> {ok, State}.
handle_handoff_command( _Message , _Sender, State) -> {noreply, State}.
handle_handoff_data(_Data, State) -> {reply, ok, State}.
encode_handoff_item(Key, Operation) -> term_to_binary({Key, Operation}).
is_empty(State) -> {true, State}.
terminate(_Reason, _State) -> ok.
delete(State) -> {ok, State}.

%%%%%%%%%%%%%%%%%%%%%%%%

timer() -> erlang:send_after(10000, self(), timeout).

broadcast(State, Msg) ->
  erlang:cancel_timer(State#state.ping_timer),
  new_inter_dc_pub:broadcast(Msg),
  {_, Id} = Msg#interdc_txn.logid_range,
  State#state{ping_timer = timer(), last_log_id = Id}.
