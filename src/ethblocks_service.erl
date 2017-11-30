-module(ethblocks_service).
-behaviour(ranch_protocol).

-export([start_link/4]).
-export([init/4]).

start_link(Ref,Socket,Transport, Opts) ->
    Pid = spawn_link(?MODULE, init, [Ref,Socket,Transport,Opts]),
    {ok,Pid}.

init(Ref, Socket, Transport, _Opts=[]) ->
    ok = ethblocks_blockvalue:subscribe(self()),
    ok = ranch:accept_ack(Ref),
    inet:setopts(Socket,[{active,true},{delay_send, false}]), 
    loop(Socket, Transport,false).

loop(Socket, Transport,Mute) ->
    receive 
        quit -> Transport:close(Socket);
        {tcp, Socket, Data} when Mute == false ->
            lager:info("Remote end send us some garbage:~p",[Data]),
            loop(Socket, Transport,true);
        {tcp_closed, Socket} -> Transport:close(Socket);
        {new_block,Nr,Value} ->
            send_block(Transport,Socket,Nr,Value),
            loop(Socket, Transport,Mute);
        Msg ->
            lager:debug("Received unsolicited msg:~p",[Msg]),
            loop(Socket, Transport,Mute)
    end.


send_block(Transport,Socket,Nr,Value) when Value > ( (1 bsl 32) -1 ) ->
    send_block(Transport,Socket,Nr, ( (1 bsl 32) -1 ));

send_block(Transport,Socket,Nr,Value) ->
    Msg = <<Nr:32,Value:32>>,
    Transport:send(Socket,Msg).

    

