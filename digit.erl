-module(digit).
-compile(export_all).


%%%% PROXY %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
proxy() ->
    process_flag(trap_exit, true),
    Self = self(),
    register(proxy, Self),
    {ok, ListenSocket} = gen_tcp:listen(12345, [{active,true},binary]),
    spawn(fun() -> clienthandler(Self, ListenSocket) end),
    proxy_loop([],0).


proxy_loop(PIDList, Coord) ->
    receive
        {From, client, Data} ->
            io:fwrite("~p client said ~p~n",[From, Data]),
            Coord ! {self(), {From, client, Data}};

        {From, new_server} ->
            NewPIDList = [From | PIDList],
            io:format("~n((~p))New server ~p has entered the system: ~n~p~n", [self(),From, NewPIDList]),

            multicast(PIDList, {new_server, From}),
            link(From),

            NewCoord =  if Coord =:= 0 -> From;
                           Coord =/= 0 -> Coord
                        end,

            From ! {ok, NewPIDList, NewCoord, self()},
            proxy_loop(NewPIDList, NewCoord);
        {'EXIT', Coord, _} ->
            NewPIDList = lists:delete(Coord, PIDList),
            NewCoord = lists:max(NewPIDList),
            io:format("~n((~p))Coordinator ~p died~n~p~n", [self(), Coord, NewPIDList]),
            Length = len(NewPIDList),
            receive_oks({coord_change, Coord, NewCoord}, Length),
            NewCoord ! {self(), you_are_the_one},
            receive
                {NewCoord, ok, you_are_the_one} -> ok
            after infinity ->
                ok % TODO if we kill both at the same time
            end,
            proxy_loop(NewPIDList, NewCoord);


        {'EXIT', Server, _} ->
            NewPIDList = lists:delete(Server, PIDList),
            io:format("~n((~p))Server ~p died~n~p", [self(), Server, NewPIDList]),

            proxy_loop(NewPIDList, Coord);


        Other ->
            io:format("((~p))Received:~n~p~n",[self(), Other])
    end,
    proxy_loop(PIDList, Coord).

clienthandler(Master, ListenSocket) ->
    io:fwrite("clienthandler started~n"),
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    io:fwrite("socket bound~n"),
    spawn(fun() -> clienthandler(Master, ListenSocket) end),
    clienthandlerloop(Socket, Master).

clienthandlerloop(Socket, Master) ->
    receive
        {tcp, Socket, Data} ->
            io:fwrite("~p ~p~n",[Socket, Data]),
            Master ! {self(), client, Data},
            gen_tcp:send(Socket,[<<"ok">>]);
        Weird ->
            io:fwrite("received unexpected message: ~p~n",[Weird])
    end,
    clienthandlerloop(Socket, Master).

%%%% SERVER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
server(Proxy_node) ->
    {proxy, Proxy_node} ! {self(), new_server},%{{{
    process_flag(trap_exit, true),
    receive
        {ok, PIDList, Coord, Proxy} ->
            io:format("~n((~p))I'm a new server: ~n~p~nCoordinator:~p~n", [self(), PIDList, Coord]),
            lists:map (fun(PID) -> link(PID) end, PIDList),
            server_loop(PIDList, Coord, Proxy);
        Other ->
            io:format("~n((~p))Received:~n~p~n",[self(), Other])
    end.

server_loop(PIDList, Coord, Proxy) ->
    receive
        {Proxy, Ref, {new_server, NewServer}} ->
            io:format("~n((~p))New server ~p~n~p~n",[self(), NewServer, [NewServer | PIDList]]),
            Proxy ! {ok, Ref},
            server_loop([NewServer | PIDList], Coord, Proxy);

        {'EXIT', Coord, _} ->
            NewPIDList = lists:delete(Coord, PIDList),
            NewCoord = lists:max(NewPIDList),
            io:format("~n((~p))Coordinator ~p died~n~p~n", [self(),Coord, NewPIDList]),
            Proxy ! {ok, {coord_change, Coord, NewCoord}},
            if NewCoord =:= self() ->
                   receive
                       {Proxy, you_are_the_one} ->
                           Proxy ! {self(), ok, you_are_the_one}
                   end,
                   io:format("~n((~p))I'm the new coordinator!~n", [self()]);
               NewCoord =/= self() ->
                   io:format("~n((~p))New Coordinator: ~p~n", [self(), NewCoord])

            end,
            server_loop(NewPIDList, NewCoord, Proxy);

        {'EXIT', Server, _} ->
            NewPIDList = lists:delete(Server, PIDList),
            io:format("~n((~p))Server ~p died~n~p", [self(), Server, NewPIDList]),

            server_loop(NewPIDList, Coord, Proxy);
        
        {Proxy, {Client, client, Data}} ->
            [Command, Filename] = re:split(Data, "#"),
            io:fwrite("~p says do ~p ~p~n", [Client, Command, Filename]);
            % case Command of
            %     <<"commit">> ->
            %         io:fwrite("~p says do ~p ~p~n", [Client, Command, Filename]);
            %     <<"update">> ->
            %         io:fwrite("~p says do ~p ~p~n", [Client, Command, Filename]);
            %     <<"checkout">> ->
            %         io:fwrite("~p says do ~p ~p~n", [Client, Command, Filename])
            % end;

        Other ->
            io:format("~n((~p))Received:~n~p~n",[self(),Other])    
    end,
    server_loop(PIDList, Coord, Proxy).



%%%% CLIENT %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
client() ->
    {_, Socket} = gen_tcp:connect({127,0,0,1}, 12345, [binary, {active,true}]),
    client_loop(Socket).

client_loop(Socket) ->
    {ok, [Command, Filename]} = io:fread("[vega] > ","~a ~s"),
        case Command of
            commit when Filename =/= [] ->
                gen_tcp:send(Socket,["commit#", Filename]);

            checkout when Filename =/= [] ->
                gen_tcp:send(Socket,["checkout#", Filename]);

            update when Filename =/= [] ->
                gen_tcp:send(Socket,["update#", Filename]);

            _ ->
                io:fwrite("Invalid expression. Use:~n"),
                io:fwrite(" commit [filename]~n"),
                io:fwrite(" checkout [filename]~n"),
                io:fwrite(" update [filename]~n"),
                client_loop(Socket)
        end,
    receive
        {tcp, Socket, Data} ->
            io:fwrite("~p ~s~n",[Socket, Data]);

        Message ->
            Message

    end,
    client_loop(Socket).


%%%% OTHER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
multicast(PIDList, Msg) ->
    Ref = erlang:make_ref(),
    lists:map (fun(PID) -> PID ! {self(), Ref, Msg} end, PIDList),
    Length = len(PIDList),
    receive_oks(Ref, Length).

%% TODO
receive_oks(_, 0) -> ok;
receive_oks(Msg, N) ->
    receive
        {ok, Msg} ->
            ok
    after infinity ->
        ok % TODO
    end,
    receive_oks(Msg, N-1).


len([]) -> 0;
len([_|T]) -> 1 + len(T).
