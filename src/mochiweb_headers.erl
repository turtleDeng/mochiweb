%% @author Bob Ippolito <bob@mochimedia.com>
%% @copyright 2007 Mochi Media, Inc.

%% @doc Case preserving (but case insensitive) HTTP Header dictionary.

-module(mochiweb_headers).
-author('bob@mochimedia.com').
-export([empty/0, from_list/1, insert/3, enter/3, get_value/2, lookup/2]).
-export([delete_any/2, get_primary_value/2, get_combined_value/2]).
-export([default/3, enter_from_list/2, default_from_list/2]).
-export([to_list/1, make/1]).
-export([from_binary/1]).
-ifdef(TEST).
-compile(export_all).
-endif.
%% @type headers().
%% @type key() = atom() | binary() | string().
%% @type value() = atom() | binary() | string() | integer().

%% @spec empty() -> headers()
%% @doc Create an empty headers structure.
empty() ->
    gb_trees:empty().

%% @spec make(headers() | [{key(), value()}]) -> headers()
%% @doc Construct a headers() from the given list.
make(L) when is_list(L) ->
    from_list(L);
%% assume a non-list is already mochiweb_headers.
make(T) ->
    T.

%% @spec from_binary(iolist()) -> headers()
%% @doc Transforms a raw HTTP header into a mochiweb headers structure.
%%
%%      The given raw HTTP header can be one of the following:
%%
%%      1) A string or a binary representing a full HTTP header ending with
%%         double CRLF.
%%         Examples:
%%         ```
%%         "Content-Length: 47\r\nContent-Type: text/plain\r\n\r\n"
%%         <<"Content-Length: 47\r\nContent-Type: text/plain\r\n\r\n">>'''
%%
%%      2) A list of binaries or strings where each element represents a raw
%%         HTTP header line ending with a single CRLF.
%%         Examples:
%%         ```
%%         [<<"Content-Length: 47\r\n">>, <<"Content-Type: text/plain\r\n">>]
%%         ["Content-Length: 47\r\n", "Content-Type: text/plain\r\n"]
%%         ["Content-Length: 47\r\n", <<"Content-Type: text/plain\r\n">>]'''
%%
from_binary(RawHttpHeader) when is_binary(RawHttpHeader) ->
    from_binary(RawHttpHeader, []);
from_binary(RawHttpHeaderList) ->
    from_binary(list_to_binary([RawHttpHeaderList, "\r\n"])).

from_binary(RawHttpHeader, Acc) ->
    case erlang:decode_packet(httph, RawHttpHeader, []) of
        {ok, {http_header, _, H, _, V}, Rest} ->
            from_binary(Rest, [{H, V} | Acc]);
        _ ->
            make(Acc)
    end.

%% @spec from_list([{key(), value()}]) -> headers()
%% @doc Construct a headers() from the given list.
from_list(List) ->
    lists:foldl(fun ({K, V}, T) -> insert(K, V, T) end, empty(), List).

%% @spec enter_from_list([{key(), value()}], headers()) -> headers()
%% @doc Insert pairs into the headers, replace any values for existing keys.
enter_from_list(List, T) ->
    lists:foldl(fun ({K, V}, T1) -> enter(K, V, T1) end, T, List).

%% @spec default_from_list([{key(), value()}], headers()) -> headers()
%% @doc Insert pairs into the headers for keys that do not already exist.
default_from_list(List, T) ->
    lists:foldl(fun ({K, V}, T1) -> default(K, V, T1) end, T, List).

%% @spec to_list(headers()) -> [{key(), string()}]
%% @doc Return the contents of the headers. The keys will be the exact key
%%      that was first inserted (e.g. may be an atom or binary, case is
%%      preserved).
to_list(T) ->
    F = fun ({K, {array, L}}, Acc) ->
                L1 = lists:reverse(L),
                lists:foldl(fun (V, Acc1) -> [{K, V} | Acc1] end, Acc, L1);
            (Pair, Acc) ->
                [Pair | Acc]
        end,
    lists:reverse(lists:foldl(F, [], gb_trees:values(T))).

%% @spec get_value(key(), headers()) -> string() | undefined
%% @doc Return the value of the given header using a case insensitive search.
%%      undefined will be returned for keys that are not present.
get_value(K, T) ->
    case lookup(K, T) of
        {value, {_, V}} ->
            expand(V);
        none ->
            undefined
    end.

%% @spec get_primary_value(key(), headers()) -> string() | undefined
%% @doc Return the value of the given header up to the first semicolon using
%%      a case insensitive search. undefined will be returned for keys
%%      that are not present.
get_primary_value(K, T) ->
    case get_value(K, T) of
        undefined ->
            undefined;
        V ->
            lists:takewhile(fun (C) -> C =/= $; end, V)
    end.

%% @spec get_combined_value(key(), headers()) -> string() | undefined
%% @doc Return the value from the given header using a case insensitive search.
%%      If the value of the header is a comma-separated list where holds values
%%      are all identical, the identical value will be returned.
%%      undefined will be returned for keys that are not present or the
%%      values in the list are not the same.
%%
%%      NOTE: The process isn't designed for a general purpose. If you need
%%            to access all values in the combined header, please refer to
%%            '''tokenize_header_value/1'''.
%%
%%      Section 4.2 of the RFC 2616 (HTTP 1.1) describes multiple message-header
%%      fields with the same field-name may be present in a message if and only
%%      if the entire field-value for that header field is defined as a
%%      comma-separated list [i.e., #(values)].
get_combined_value(K, T) ->
    case get_value(K, T) of
        undefined ->
            undefined;
        V ->
            case sets:to_list(sets:from_list(tokenize_header_value(V))) of
                [Val] ->
                    Val;
                _ ->
                    undefined
            end
    end.

%% @spec lookup(key(), headers()) -> {value, {key(), string()}} | none
%% @doc Return the case preserved key and value for the given header using
%%      a case insensitive search. none will be returned for keys that are
%%      not present.
lookup(K, T) ->
    case gb_trees:lookup(normalize(K), T) of
        {value, {K0, V}} ->
            {value, {K0, expand(V)}};
        none ->
            none
    end.

%% @spec default(key(), value(), headers()) -> headers()
%% @doc Insert the pair into the headers if it does not already exist.
default(K, V, T) ->
    K1 = normalize(K),
    V1 = any_to_list(V),
    try gb_trees:insert(K1, {K, V1}, T)
    catch
        error:{key_exists, _} ->
            T
    end.

%% @spec enter(key(), value(), headers()) -> headers()
%% @doc Insert the pair into the headers, replacing any pre-existing key.
enter(K, V, T) ->
    K1 = normalize(K),
    V1 = any_to_list(V),
    gb_trees:enter(K1, {K, V1}, T).

%% @spec insert(key(), value(), headers()) -> headers()
%% @doc Insert the pair into the headers, merging with any pre-existing key.
%%      A merge is done with Value = V0 ++ ", " ++ V1.
insert(K, V, T) ->
    K1 = normalize(K),
    V1 = any_to_list(V),
    try gb_trees:insert(K1, {K, V1}, T)
    catch
        error:{key_exists, _} ->
            {K0, V0} = gb_trees:get(K1, T),
            V2 = merge(K1, V1, V0),
            gb_trees:update(K1, {K0, V2}, T)
    end.

%% @spec delete_any(key(), headers()) -> headers()
%% @doc Delete the header corresponding to key if it is present.
delete_any(K, T) ->
    K1 = normalize(K),
    gb_trees:delete_any(K1, T).

%% Internal API

tokenize_header_value(undefined) ->
    undefined;
tokenize_header_value(V) ->
    reversed_tokens(trim_and_reverse(V, false), [], []).

trim_and_reverse([S | Rest], Reversed) when S=:=$ ; S=:=$\n; S=:=$\t ->
    trim_and_reverse(Rest, Reversed);
trim_and_reverse(V, false) ->
    trim_and_reverse(lists:reverse(V), true);
trim_and_reverse(V, true) ->
    V.

reversed_tokens([], [], Acc) ->
    Acc;
reversed_tokens([], Token, Acc) ->
    [Token | Acc];
reversed_tokens("\"" ++ Rest, [], Acc) ->
    case extract_quoted_string(Rest, []) of
        {String, NewRest} ->
            reversed_tokens(NewRest, [], [String | Acc]);
        undefined ->
            undefined
    end;
reversed_tokens("\"" ++ _Rest, _Token, _Acc) ->
    undefined;
reversed_tokens([C | Rest], [], Acc) when C=:=$ ;C=:=$\n;C=:=$\t;C=:=$, ->
    reversed_tokens(Rest, [], Acc);
reversed_tokens([C | Rest], Token, Acc) when C=:=$ ;C=:=$\n;C=:=$\t;C=:=$, ->
    reversed_tokens(Rest, [], [Token | Acc]);
reversed_tokens([C | Rest], Token, Acc) ->
    reversed_tokens(Rest, [C | Token], Acc);
reversed_tokens(_, _, _) ->
    undefeined.

extract_quoted_string([], _Acc) ->
    undefined;
extract_quoted_string("\"\\" ++ Rest, Acc) ->
    extract_quoted_string(Rest, "\"" ++ Acc);
extract_quoted_string("\"" ++ Rest, Acc) ->
    {Acc, Rest};
extract_quoted_string([C | Rest], Acc) ->
    extract_quoted_string(Rest, [C | Acc]).

expand({array, L}) ->
    mochiweb_util:join(lists:reverse(L), ", ");
expand(V) ->
    V.

merge("set-cookie", V1, {array, L}) ->
    {array, [V1 | L]};
merge("set-cookie", V1, V0) ->
    {array, [V1, V0]};
merge(_, V1, V0) ->
    V0 ++ ", " ++ V1.

normalize(K) when is_list(K) ->
    string:to_lower(K);
normalize(K) when is_atom(K) ->
    normalize(atom_to_list(K));
normalize(K) when is_binary(K) ->
    normalize(binary_to_list(K)).

any_to_list(V) when is_list(V) ->
    V;
any_to_list(V) when is_atom(V) ->
    atom_to_list(V);
any_to_list(V) when is_binary(V) ->
    binary_to_list(V);
any_to_list(V) when is_integer(V) ->
    integer_to_list(V).

