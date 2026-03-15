%%%-------------------------------------------------------------------
%%% @doc Atom feed search agent.
%%%
%%% Reads a list of Atom feed URLs from atom_config.json, fetches each
%%% feed, and returns entries whose title, link or summary matches
%%% the search query.
%%%
%%% Maintains a memory of URLs already returned so duplicate entries
%%% across successive queries are filtered out.
%%%
%%% atom_config.json format:
%%%   { "atom_feeds": ["https://example.com/feed.atom", ...] }
%%%
%%% Key differences from RSS:
%%%   - Root element is <feed> instead of <rss>
%%%   - Items are <entry> instead of <item>
%%%   - Link is <link href="..."/> (attribute) instead of <link>url</link>
%%%   - Summary is <summary> or <content> instead of <description>
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, NewMemory}.
%%% Memory schema: #{seen => #{binary_url => true}}.
%%% @end
%%%-------------------------------------------------------------------
-module(atom_filter_app).
-behaviour(application).

-include_lib("xmerl/include/xmerl.hrl").

-export([start/2, stop/1]).
-export([handle/2]).

-define(CAPABILITIES, [
    <<"atom">>,
    <<"feeds">>,
    <<"news">>
]).

%%====================================================================
%% Application behaviour
%%====================================================================

start(_StartType, _StartArgs) ->
    em_filter:start_agent(atom_filter, ?MODULE, #{
        capabilities => ?CAPABILITIES,
        memory       => ets
    }).

stop(_State) ->
    em_filter:stop_agent(atom_filter).

%%====================================================================
%% Agent handler
%%====================================================================

handle(Body, Memory) when is_binary(Body) ->
    Seen    = maps:get(seen, Memory, #{}),
    Embryos = generate_embryo_list(Body),
    Fresh   = [E || E <- Embryos, not maps:is_key(url_of(E), Seen)],
    NewSeen = lists:foldl(fun(E, Acc) ->
        Acc#{url_of(E) => true}
    end, Seen, Fresh),
    {Fresh, Memory#{seen => NewSeen}};

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
    %% Atom links carry the URL in the href attribute, not as text content.
    Link    = xml_attr(xmerl_xpath:string("./link",            Entry), "href"),
    Summary = xml_text(xmerl_xpath:string("./summary/text()", Entry)),
    Content = xml_text(xmerl_xpath:string("./content/text()", Entry)),
    %% Use summary when available, fall back to content.
    Body    = case Summary of "" -> Content; _ -> Summary end,
    Matches =
        string:str(string:lowercase(Title),   Query) > 0 orelse
        string:str(string:lowercase(Link),    Query) > 0 orelse
        string:str(string:lowercase(Body),    Query) > 0,
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

%%--------------------------------------------------------------------
%% xmerl helpers
%%--------------------------------------------------------------------

%% Extracts the text content of a node.
xml_text([#xmlText{value = V} | _]) -> V;
xml_text(_)                          -> "".

%% Extracts a named attribute value from an element node.
xml_attr([#xmlElement{attributes = Attrs} | _], Name) ->
    AtomName = list_to_atom(Name),
    case lists:keyfind(AtomName, #xmlAttribute.name, Attrs) of
        #xmlAttribute{value = V} -> V;
        false                    -> ""
    end;
xml_attr(_, _) -> "".

%%====================================================================
%% Internal helpers
%%====================================================================

-spec url_of(map()) -> binary().
url_of(#{<<"properties">> := #{<<"url">> := Url}}) -> Url;
url_of(_) -> <<>>.
