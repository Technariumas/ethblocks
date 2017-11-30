-module(ethblocks_wsclient).

-behaviour(gen_server).

-export([start_link/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-record(state, {
    wsaddr,
    wsport,
    wspath, 
    gun_pid,
    ws_ref,
    sub_id}).

-define(RETRY_TIME,10000).

%%--------8><------------API------------8><-----------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

%%--------8><---------CALLBACKS---------8><-----------------
init([]) ->
    case { application:get_env(ethblocks,wsaddr,undefined),
           application:get_env(ethblocks,wsport,undefined),
           application:get_env(ethblocks,wspath,undefined)} of
        {A,B,C} when A ==undefined, B==undefined,C==undefined ->
             {stop,no_environment};
        {WSAddr,WSPort,WSPath} ->
            self() ! connect,
            {ok, #state{wsaddr=WSAddr,wsport=WSPort,wspath=WSPath}}
    end.


handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.

handle_cast({got_json,Json}, State) ->
    lager:info("Got JSON: ~p",[Json]),
    {noreply, State};

handle_cast({new_block,Json}, State) ->
    lager:info("Got Block: ~p",[Json]),
    {noreply, State};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(connect, State = #state{wsaddr=WSAddr,wsport=WSPort}) ->
    case gun:open(WSAddr,WSPort) of
    {ok,Pid} when is_pid(Pid) ->
        {noreply, State#state{gun_pid=Pid}};
    _Else -> 
        timer:send_after(?RETRY_TIME,self(),connect),
        {noreply, State}
    end;

handle_info({gun_down,Pid,_Proto,_Reason,_KilledStreams,_UnprocessedStreams}, State = #state{gun_pid=Pid}) ->
    {noreply,State#state{ws_ref=undefined}};

handle_info({gun_up,Pid,http}, State = #state{gun_pid = Pid, wspath=WSPath,ws_ref=WSR}) when WSR == undefined ->
    WSRef = gun:ws_upgrade(Pid,WSPath),
    {noreply, State#state{ws_ref=WSRef}};

handle_info({gun_ws_upgrade,Pid,ok, _Attrs}, State = #state{gun_pid=Pid}) ->
        Msg = <<"{\"id\": 666, \"method\": \"eth_subscribe\", \"params\": [\"newHeads\", {}]}">>,
        gun:ws_send(Pid,{binary,Msg}),
    {noreply,State};


handle_info({gun_ws,Pid,{text,Json}},State = #state{gun_pid=Pid,sub_id=SubId}) ->
    case decode_json(Json) of
        {ok,#{<<"id">>:=Id, <<"result">>:=Result } } when Id == 666-> % received subscription response
            lager:info("Got subscription Id:~p",[Result]),
            {noreply,State#state{sub_id=Result}};

        {ok,#{<<"id">>:=Id, <<"result">>:=Block } } when Id == 777-> % received tx lookup response
            {Number,Sum} = parse_block(Block),
            ETH = Sum div 1000000000000000000,
            gen_server:cast(ethblocks_blockvalue,{new_block,Number,ETH}),
            lager:debug("Got block #~p with value of ~p ETH",[Number,Sum div 1000000000000000000]),
            {noreply,State};

        {ok,#{<<"method">>:=<<"eth_subscription">>,
              <<"params">>:= #{<<"subscription">>:=SubId, <<"result">>:=Result } }} ->
            #{<<"number">>:=Nr} = Result,
            retrieve_transactions(Pid,Nr), 
            {noreply,State};

        {ok,Msg} ->
            gen_server:cast(self(),{got_json,Msg}),
            {noreply,State};

        _Else ->
            {noreply,State}
    end;
            
handle_info(Info, State) ->
    lager:info("Unhandled Info msg: ~p",[Info]),
    {noreply, State}.

terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

decode_json(Json) ->
    try
        {ok,jiffy:decode(Json,[return_maps])}
    catch A:B ->
        lager:info("Jiffy decode failure:~p:~p",[A, B]),
        error
    end.

retrieve_transactions(Pid,Nr) ->
    R =  << <<"{\"jsonrpc\":\"2.0\",\"method\":\"eth_getBlockByNumber\",\"params\":[\"">>/binary, Nr/binary,<<"\", true],\"id\":777}">>/binary >>,
    gun:ws_send(Pid,{binary,R}).

parse_block(#{<<"number">>:=Nr,<<"transactions">>:=Trans}) ->
    { hex_to_dec(binary_to_list(Nr)),parse_transactions(Trans)}.

hex_to_dec([$0,$x|Rest]) ->
    list_to_integer(Rest,16).

parse_transactions(Trans) ->
    Total = fun (#{<<"value">>:=Val},Sum) ->
        Sum + hex_to_dec(binary_to_list(Val))
    end,
    lists:foldl(Total,0,Trans).


%%% lookup {"jsonrpc":"2.0","method":"eth_getBlockByNumber","params":["0x1b4", true],"id":1}
