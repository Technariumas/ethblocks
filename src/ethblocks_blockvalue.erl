-module(ethblocks_blockvalue).
-behaviour(gen_server).

-export([start_link/0]).

-export([init/1,
         handle_call/3,
         handle_cast/2,
         handle_info/2,
         terminate/2,
         code_change/3]).

-export([subscribe/1]).

-define(TABLE_NAME,ethblocks_subscribers).

-record(state, {}).

%%--------8><------------API------------8><-----------------
start_link() ->
    gen_server:start_link({local, ?MODULE}, ?MODULE, [], []).

subscribe(Pid) -> gen_server:call(?MODULE,{subscribe,Pid}).

%%--------8><---------CALLBACKS---------8><-----------------

init([]) ->
    ?TABLE_NAME = ets:new(?TABLE_NAME,[named_table,set]),
   {ok,_} = ranch:start_listener(ethblocks_listener, 1, ranch_tcp,
                    [{port, 5555}], ethblocks_service, []),
   {ok, #state{}}.

handle_call({subscribe,Pid}, _From, State) ->
    MonRef = monitor(process,Pid),
    ets:insert(?TABLE_NAME,{MonRef,Pid}),
    {reply, ok, State};

handle_call(_Request, _From, State) ->
    Reply = ok,
    {reply, Reply, State}.


handle_cast({new_block,Nr,Value}, State) ->
    send_all( {new_block,Nr,Value}),
    {noreply, State};

handle_cast(Msg, State) ->
    lager:info("Got unsolicited cast:~p",[Msg]),
    {noreply, State}.

handle_info({'DOWN',MonRef,_Type,_Object,_Info}, State) ->
    ets:delete(?TABLE_NAME,MonRef),
    {noreply, State};

handle_info(_Info, State) -> {noreply, State}.


terminate(_Reason, _State) ->
    send_all(quit),
    ranch:stop_listener(ethblocks_listener),
    ok.

code_change(_OldVsn, State, _Extra) -> {ok, State}.

%%--------8><---------PRIVATE_PARTS------8><----------------

send_all(Msg) ->
    Notifier = fun ({_MonRef,Pid},_Acc) -> Pid ! Msg end,
    ets:foldl(Notifier,ok,?TABLE_NAME).




