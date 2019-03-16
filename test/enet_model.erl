-module(enet_model).
-behaviour(proper_statem).

-include_lib("proper/include/proper.hrl").

-export([
         initial_state/0,
         command/1,
         precondition/2,
         postcondition/3,
         next_state/3
        ]).

-export([
         mock_connect_fun/0,
         mock_start_worker/2,
         pretty_print_commands/1
        ]).


-record(state,
        {
          hosts = []
        }).

-record(host,
        {
          port,
          peer_count = 0,
          peer_limit,
          channel_limit,
          peers = []
        }).

-record(peer,
        {
          connect_id,
          pid,
          channel_count,
          channels = #{}
        }).


%%%
%%% Initial state
%%%

initial_state() ->
    #state{}.


%%%
%%% Commands
%%%

command(#state{ hosts = [] }) ->
    {call, enet_sync, start_host, [connect_fun(), host_options()]};

command(S) ->
    Peers = [P || H <- S#state.hosts, P <- H#host.peers],
    oneof(
      [
       {call, enet_sync, start_host, [connect_fun(), host_options()]},

       ?LET(#host{ port = Port }, started_host(S),
            {call, enet_sync, stop_host, [Port]}),

       ?LET(#host{ port = Port, channel_limit = Limit },
            started_host(S),
            {call, enet_sync, connect,
             [host_port(S), Port, channel_count(Limit)]})
      ]

      ++ [?LET(#peer{ connect_id = ConnectID }, oneof(Peers),
               begin
                   [LPid, RPid] =
                       [P#peer.pid ||
                           H <- S#state.hosts,
                           P = #peer{ connect_id = C } <- H#host.peers,
                           C =:= ConnectID],
                   {call, enet_sync, disconnect, [LPid, RPid]}
               end)
          || Peers =/= []]

      ++ [{call, enet_sync, send_unsequenced, [channel_pid(S), message_data()]}
          || Peers =/= []]

      ++ [{call, enet_sync, send_unreliable, [channel_pid(S), message_data()]}
          || Peers =/= []]

      ++ [{call, enet_sync, send_reliable, [channel_pid(S), message_data()]}
          || Peers =/= []]
     ).



%%%
%%% Pre-conditions
%%%

precondition(S, {call, enet_sync, stop_host, [Port]}) ->
    case get_host_with_port(S, Port) of
        false -> false;
        _Host -> true
    end;

precondition(S, {call, enet_sync, connect, [_HostPid, Port, _ChannelCount]}) ->
    case get_host_with_port(S, Port) of
        false -> false;
        _Host -> true
    end;

precondition(_S, {call, _, _, _}) ->
    true.



%%%
%%% State transitions
%%%

next_state(S, V, {call, enet_sync, start_host, [_ConnectFun, Options]}) ->
    HostPort = {call, enet_sync, get_host_port, [V]},
    {peer_limit, PeerLimit} = lists:keyfind(peer_limit, 1, Options),
    {channel_limit, ChannelLimit} = lists:keyfind(channel_limit, 1, Options),
    Host = #host{
              port = HostPort,
              peer_limit = PeerLimit,
              channel_limit = ChannelLimit
             },
    S#state{
      hosts = [Host | S#state.hosts]
     };

next_state(S, _V, {call, enet_sync, stop_host, [Port]}) ->
    Host = lists:keyfind(Port, #host.port, S#state.hosts),
    ConnectIDs = [CID || #peer{ connect_id = CID } <- Host#host.peers],
    TheOtherHosts = lists:keydelete(Port, #host.port, S#state.hosts),
    Hosts = lists:map(
              fun(H = #host{ peers = Ps }) ->
                      Peers = [P || P <- Ps, not lists:member(P#peer.connect_id,
                                                              ConnectIDs)],
                      H#host{
                        peer_count = length(Peers),
                        peers = Peers
                       }
              end,
              TheOtherHosts),
    S#state{ hosts = Hosts };

next_state(S, V, {call, enet_sync, connect, [LPort, RPort, ChannelCount]}) ->
    H1 = get_host_with_port(S, LPort),
    H2 = get_host_with_port(S, RPort),
    case {H1, H2} of
        {_, #host{ peer_limit = L, peer_count = L }} ->
            %% Trying to connect to a full remote host -> timeout
            S;
        {#host{ peer_limit = L, peer_count = L }, _} ->
            %% Trying to connect from a full host -> peer_limit_reached
            S;
        {H1, H1 = #host{ peer_limit = L, peer_count = C }} when L - C < 2 ->
            %% Trying to connect to own host without room for two new peers
            S;
        {H1, H1 = #host{ peer_count = C }} ->
            %% Trying to connect to own host
            PeerPid = {call, enet_sync, get_local_peer_pid, [V]},
            Channels = {call, enet_sync, get_local_channels, [V]},
            RemotePeerPid = {call, enet_sync, get_remote_peer_pid, [V]},
            RemoteChannels = {call, enet_sync, get_remote_channels, [V]},
            ConnectID = {call, enet_peer, get_connect_id, [PeerPid]},
            Peer1 = #peer{
                       connect_id = ConnectID,
                       pid = PeerPid,
                       channel_count = ChannelCount,
                       channels = Channels
                      },
            Peer2 = #peer{
                       connect_id = ConnectID,
                       pid = RemotePeerPid,
                       channel_count = ChannelCount,
                       channels = RemoteChannels
                      },
            NewH1 = H1#host{
                     peer_count = C + 2,
                     peers = [Peer1, Peer2 | H1#host.peers]
                    },
            Hosts1 = lists:keyreplace(LPort, #host.port, S#state.hosts, NewH1),
            S#state{
              hosts = Hosts1
             };
        {H1, H2 = #host{}} ->
            PeerPid = {call, enet_sync, get_local_peer_pid, [V]},
            Channels = {call, enet_sync, get_local_channels, [V]},
            RemotePeerPid = {call, enet_sync, get_remote_peer_pid, [V]},
            RemoteChannels = {call, enet_sync, get_remote_channels, [V]},
            ConnectID = {call, enet_peer, get_connect_id, [PeerPid]},
            Peer1 = #peer{
                       connect_id = ConnectID,
                       pid = PeerPid,
                       channel_count = ChannelCount,
                       channels = Channels
                      },
            Peer2 = #peer{
                       connect_id = ConnectID,
                       pid = RemotePeerPid,
                       channel_count = ChannelCount,
                       channels = RemoteChannels
                      },
            NewH1 = H1#host{
                     peer_count = H1#host.peer_count + 1,
                     peers = [Peer1 | H1#host.peers]
                    },
            NewH2 = H2#host{
                     peer_count = H2#host.peer_count + 1,
                     peers = [Peer2 | H2#host.peers]
                    },
            Hosts1 = lists:keyreplace(LPort, #host.port, S#state.hosts, NewH1),
            Hosts2 = lists:keyreplace(RPort, #host.port, Hosts1, NewH2),
            S#state{
              hosts = Hosts2
             }
    end;

next_state(S, _V, {call, enet_sync, disconnect, [LPid, _RPid]}) ->
    [ConnectID] = [ConnectID
                   || #host{ peers = Peers } <- S#state.hosts,
                      #peer{ connect_id = ConnectID, pid = Pid } <- Peers,
                      Pid =:= LPid],
    Hosts = lists:map(
              fun(H = #host{ peers = Ps }) ->
                      Peers = [P || P = #peer{ connect_id = C } <- Ps,
                                    C =/= ConnectID],
                      H#host{
                        peer_count = length(Peers),
                        peers = Peers
                       }
              end,
              S#state.hosts),
    S#state{ hosts = Hosts };

next_state(S, _V, {call, _, send_unsequenced, [_ChannelPid, _Data]}) ->
    S;

next_state(S, _V, {call, _, send_unreliable, [_ChannelPid, _Data]}) ->
    S;

next_state(S, _V, {call, _, send_reliable, [_ChannelPid, _Data]}) ->
    S.


%%%
%%% Post-conditions
%%%

postcondition(_S, {call, enet_sync, start_host, [_ConnectFun, _Opts]}, Res) ->
    case Res of
        {error, _Reason} -> false;
        {ok, _Port}      -> true
    end;

postcondition(S, {call, enet_sync, stop_host, [Port]}, Res) ->
    case lists:keyfind(Port, #host.port, S#state.hosts) of
        false   -> Res =:= {error, not_found};
        #host{} -> Res =:= ok
    end;

postcondition(S, {call, enet_sync, connect, [LPort, RPort, _C]}, Res) ->
    H1 = get_host_with_port(S, LPort),
    H2 = get_host_with_port(S, RPort),
    case {H1, H2} of
        {#host{ peer_limit = L, peer_count = L }, #host{}} ->
            %% Tried to connect from a full host -> peer_limit_reached
            Res =:= {error, reached_peer_limit};
        {#host{}, #host{ peer_limit = L, peer_count = L }} ->
            %% Tried to connect to a full remote host -> timeout
            Res =:= {error, local_timeout};
        {H1, H1 = #host{ peer_limit = L, peer_count = C }} when L - C =:= 1 ->
            %% Tried to connect to own host without room for two new peers
            case Res of
                {error, local_timeout}      -> true;
                {error, reached_peer_limit} -> true;
                _                           -> false
            end;
        {#host{}, #host{}} ->
            case Res of
                {_LPid, _LChannels, _RPid, _RChannels} -> true;
                {error, _Reason}                       -> false
            end;
        {_H1, _H2} ->
            false
    end;

postcondition(_S, {call, enet_sync, disconnect, [_LPeer, _RPeer]}, Res) ->
    Res =:= ok;

postcondition(_S, {call, _, send_unsequenced, [_Channel, _Data]}, Res) ->
    Res =:= ok;

postcondition(_S, {call, _, send_unreliable, [_Channel, _Data]}, Res) ->
    Res =:= ok;

postcondition(_S, {call, _, send_reliable, [_Channel, _Data]}, Res) ->
    Res =:= ok.


%%%
%%% Properties
%%%

prop_sync_loopback() ->
    application:ensure_all_started(enet),
    ?FORALL(Cmds, commands(?MODULE),
            ?WHENFAIL(
               pretty_print_commands(Cmds),
               ?TRAPEXIT(
                  begin
                      {History, S, Res} = run_commands(?MODULE, Cmds),
                      lists:foreach(
                        fun(#host{ port = Port }) ->
                                case enet_sync:stop_host(Port) of
                                    ok              -> ok;
                                    {error, Reason} ->
                                        io:format("\n\nCleanup error: enet_sync:stop_host/1: ~p\n\n", [Reason])
                                end
                        end,
                        S#state.hosts),
                      case Res of
                          ok -> true;
                          _  ->
                              io:format("~nHistory: ~p~nState: ~p~nRes: ~p~n",
                                        [History, S, Res]),
                              false
                      end
                  end))).


%%%
%%% Generators
%%%

connect_fun() ->
    oneof([symbolic_connect_fun(), connect_mfa()]).

symbolic_connect_fun() ->
    {call, enet_model, mock_connect_fun, []}.

connect_mfa() ->
    {enet_model, mock_start_worker, [{call, erlang, self, []}]}.

mock_connect_fun() ->
    Self = self(),
    fun(PeerInfo) ->
            Self ! PeerInfo,
            {ok, Self}
    end.

mock_start_worker(Self, PeerInfo) ->
    Self ! PeerInfo,
    {ok, Self}.

busy_host_port(S = #state{}) ->
    ?LET(#host{ port = Port }, started_host(S), Port).

host_options() ->
    [{peer_limit, integer(1, 255)}, {channel_limit, integer(1, 8)}].

started_host(#state{ hosts = Hosts }) ->
    oneof(Hosts).

host_port(#state{ hosts = Hosts }) ->
    oneof([Port || #host{ port = Port } <- Hosts]).

peer_pid(#state{ hosts = Hosts }) ->
    oneof([Pid || #host{ peers = Peers } <- Hosts,
                  #peer{ pid = Pid }     <- Peers,
                  Pid =/= undefined]).

connect_id(#state{ hosts = Hosts }) ->
    oneof([ConnectID
           || #host{ peers = Peers } <- Hosts,
              #peer{ connect_id = ConnectID, pid = undefined } <- Peers]).


channel_pid(#state{ hosts = Hosts }) ->
    ?LET(#host{ peers = Peers },
         ?SUCHTHAT(#host{ peers = Peers }, oneof(Hosts),
                   Peers =/= []),
         ?LET(#peer{ channels = Channels, channel_count = Count }, oneof(Peers),
              ?LET(ID, integer(0, Count - 1),
                   {call, enet_sync, get_channel, [ID, Channels]}))).


channel_count(Limit) ->
    integer(1, Limit).

local_ip() ->
    "127.0.0.1".

message_data() ->
    binary().


%%%
%%% Misc
%%%

get_host_with_port(#state{ hosts = Hosts }, Port) ->
    lists:keyfind(Port, #host.port, Hosts).

pretty_print_commands(Commands) ->
    io:format("~n=TEST CASE=============================~n~n"),
    lists:foreach(fun (C) ->
                          io:format("  ~s~n", [pprint(C)])
                  end,
                  Commands),
    io:format("~n=======================================~n").

pprint({set, Var, Call}) ->
    io_lib:format("~s = ~s", [pprint(Var), pprint(Call)]);
pprint({var, N}) ->
    io_lib:format("Var~p", [N]);
pprint({call, M, F, Args}) ->
    PPArgs = [pprint(A) || A <- Args],
    io_lib:format("~p:~p(~s)", [M, F, lists:join(", ", PPArgs)]);
pprint(Other) ->
    io_lib:format("~p", [Other]).
