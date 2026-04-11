%%%-------------------------------------------------------------------
%%% @doc Atom feed search agent.
%%%
%%% Reads a list of Atom feed URLs from atom_config.json, fetches each
%%% feed, and returns entries whose title, link or summary matches
%%% the search query.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%   Site-specific filters extend atom_filter_app:base_capabilities():
%%%
%%% atom_config.json format:
%%%   { "atom_feeds": ["https://example.com/feed.atom", ...] }
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(atom_filter_app).

-include_lib("xmerl/include/xmerl.hrl").

-export([handle/2, base_capabilities/0]).

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"atom">>, <<"feeds">>, <<"news">>].

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Value, Timeout} = extract_params(JsonBinary),
    Feeds     = read_atom_config(),
    StartTime = erlang:system_time(millisecond),
    search_feeds(Feeds, string:lowercase(Value), StartTime, Timeout * 1000, []).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Value   = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Value, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

%%--------------------------------------------------------------------
%% Config
%%--------------------------------------------------------------------

read_atom_config() ->
    case file:read_file("atom_config.json") of
        {ok, Bin} ->
            try json:decode(Bin) of
                #{<<"atom_feeds">> := Feeds} when is_list(Feeds) -> Feeds;
                _ -> []
            catch _:_ -> [] end;
        _ -> []
    end.

%%--------------------------------------------------------------------
%% Feed iteration
%%--------------------------------------------------------------------

search_feeds([], _Query, _Start, _Timeout, Acc) ->
    lists:reverse(Acc);
search_feeds([FeedUrl | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> lists:reverse(Acc);
        false ->
            NewAcc = fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc),
            search_feeds(Rest, Query, Start, Timeout, NewAcc)
    end.

fetch_and_filter_feed(FeedUrl, Query, Start, Timeout, Acc) ->
    Url = binary_to_list(FeedUrl),
    case httpc:request(get, {Url, []}, [{timeout, 5000}], [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            case xmerl_scan:string(binary_to_list(Body)) of
                {Doc, _} ->
                    Entries = xmerl_xpath:string("//entry", Doc),
                    process_entries(Entries, Query, Start, Timeout, Acc);
                _ ->
                    Acc
            end;
        _ ->
            Acc
    end.

%%--------------------------------------------------------------------
%% Entry processing
%%--------------------------------------------------------------------

process_entries([], _Query, _Start, _Timeout, Acc) ->
    Acc;
process_entries([Entry | Rest], Query, Start, Timeout, Acc) ->
    case erlang:system_time(millisecond) - Start >= Timeout of
        true  -> Acc;
        false ->
            NewAcc = case process_entry(Entry, Query) of
                {ok, Embryo} -> [Embryo | Acc];
                skip         -> Acc
            end,
            process_entries(Rest, Query, Start, Timeout, NewAcc)
    end.

process_entry(Entry, Query) ->
    Title   = xml_text(xmerl_xpath:string("./title/text()",   Entry)),
    Link    = xml_attr(xmerl_xpath:string("./link",            Entry), "href"),
    Summary = xml_text(xmerl_xpath:string("./summary/text()", Entry)),
    Content = xml_text(xmerl_xpath:string("./content/text()", Entry)),
    Body    = case Summary of "" -> Content; _ -> Summary end,
    Matches =
        string:str(string:lowercase(Title), Query) > 0 orelse
        string:str(string:lowercase(Link),  Query) > 0 orelse
        string:str(string:lowercase(Body),  Query) > 0,
    case Matches of
        true ->
            {ok, #{
                <<"properties">> => #{
                    <<"url">>    => list_to_binary(Link),
                    <<"title">>  => unicode:characters_to_binary(Title),
                    <<"resume">> => unicode:characters_to_binary(Body)
                }
            }};
        false ->
            skip
    end.

xml_text([#xmlText{value = V} | _]) -> V;
xml_text(_)                          -> "".

xml_attr([#xmlElement{attributes = Attrs} | _], Name) ->
    AtomName = list_to_atom(Name),
    case lists:keyfind(AtomName, #xmlAttribute.name, Attrs) of
        #xmlAttribute{value = V} -> V;
        false                    -> ""
    end;
xml_attr(_, _) -> "".
