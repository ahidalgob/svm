-module(svm).
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
            io:format("~n((~p))Coordinator ~p died~n~p~n", [self(), Coord, NewPIDList]),
            NewCoord = if NewPIDList =/= [] -> lists:max(NewPIDList);
                          NewPIDList =:= [] -> proxy_loop(NewPIDList, 0)
                       end,
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
            Master ! {self(), client, Data};

        {commitok, Ver, _} ->
            gen_tcp:send(Socket, [integer_to_binary(Ver)]);

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
            State = if Coord =/= self() ->
                            Coord ! {self(), need_state},
                            receive
                                {Coord, need_state, CoordState} -> CoordState
                            end;
                       Coord =:= self() ->
                           []
                    end,
            server_loop(PIDList, Coord, Proxy, State);
        Other ->
            io:format("~n((~p))Received:~n~p~n",[self(), Other])
    end.

server_loop(PIDList, Coord, Proxy, State) ->
    receive
        {Proxy, Ref, {new_server, NewServer}} ->
            io:format("~n((~p))New server ~p~n~p~n",[self(), NewServer, [NewServer | PIDList]]),
            Proxy ! {ok, Ref},
            server_loop([NewServer | PIDList], Coord, Proxy, State);

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
            server_loop(NewPIDList, NewCoord, Proxy, State);

        {'EXIT', Server, _} ->
            NewPIDList = lists:delete(Server, PIDList),
            io:format("~n((~p))Server ~p died~n~p", [self(), Server, NewPIDList]),

            server_loop(NewPIDList, Coord, Proxy, State);

        {From, need_state} ->
            From ! {self(), need_state, State},
            server_loop(PIDList, Coord, Proxy, State);

        {Coord, Ref, {commit, Filename, Ver}} ->
            io:fwrite("commit ~p  ~p~n",[Filename, Ver]),
            NewState = [{Filename, Ver} | State],
            Coord ! {ok, Ref},
            server_loop(PIDList, Coord, Proxy, NewState);

        {Proxy, {Client, client, Data}} ->
            [Command, Filename] = split_binary_to_atoms(Data, "#"),

            Ver = case lists:any(fun(X) -> case X of {Filename, _} -> true; _ -> false end end, State) of
                            true -> L = lists:filter(fun(X) -> case X of {Filename, _} -> true; _ -> false end end, State),
                                    lists:max(lists:map(fun({_, V}) -> V end, L));
                            false -> -1
                        end,

            case Command of
                commit -> io:fwrite("~p says do ~p ~p  ~p~n", [Client, Command, Filename, Ver]),
                          multicast(PIDList -- [Coord], {commit, Filename, Ver+1}),
                          Client ! {commitok, Ver+1, Filename},
                          NewState = [{Filename, Ver+1} | State],
                          server_loop(PIDList, Coord, Proxy, NewState);
                checkout -> Proxy ! {checkoutok, Ver, Filename, Client},
                            io:fwrite("~p says do ~p ~p  ~p~n", [Client, Command, Filename, Ver])
            end;
        Other ->
            io:format("~n((~p))Received:~n~p~n",[self(),Other])
    end,
    server_loop(PIDList, Coord, Proxy, State).



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


            _ ->
                io:fwrite("Invalid expression. Use:~n"),
                io:fwrite(" commit [filename]~n"),
                io:fwrite(" checkout [filename]~n"),
                client_loop(Socket)
        end,
    receive
        {tcp, Socket, Data} ->
            io:fwrite("~p ~s~n",[Socket, Data]);

        Message ->
            io:fwrite("~p", [Message])

    end,
    client_loop(Socket).


%%%% OTHER %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
multicast(PIDList, Msg) ->
    io:fwrite("multicasting ~p  ~p~n", [Msg, PIDList]),
    Ref = erlang:make_ref(),
    lists:map (fun(PID) -> PID ! {self(), Ref, Msg} end, PIDList),
    Length = len(PIDList),
    receive_oks(Ref, Length).

%% TODO
receive_oks(_, 0) -> ok;
receive_oks(Ref, N) ->
    receive
        {ok, Ref} ->
            ok
    after infinity ->
        ok % TODO
    end,
    receive_oks(Ref, N-1).


len([]) -> 0;
len([_|T]) -> 1 + len(T).


split_binary_to_atoms(Bin, [Char]) -> lists:map(fun(X) -> list_to_atom(X) end, split_list(binary_to_list(Bin), Char)).

split_list([], _) -> [];
split_list(L, X) ->
    {Part, Rest} = get_list_part(L, X),
    [Part | split_list(Rest, X)].

get_list_part([], _) -> {[], []};
get_list_part([X|T], X) -> {[] , T};
get_list_part([Y|T], X) ->
    {Part, Rest} = get_list_part(T, X),
    {[Y|Part], Rest}.

