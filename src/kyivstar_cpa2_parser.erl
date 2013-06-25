-module(kyivstar_cpa2_parser).

-author('Vitali Kletsko <v.kletsko@gmail.com>').
-author('Sergiy Kostyushkin <s.kostyushkin@gmail.com>').

%% API
-export([build_request/4]).
-export([parse_response/1]).

%% API
build_request(SrcAddr, DestAddr, Msg, Opts) when is_list(Opts), 
        is_binary(SrcAddr), is_binary(DestAddr), is_binary(Msg) ->
    Id = proplists:get_value(id, Opts, 0),
    Tariff = proplists:get_value(tariff, Opts, "2000"),
    Service = proplists:get_value(service, Opts, "SMS"),
    BinId = list_to_binary(integer_to_list(Id)),
    BinTariff = list_to_binary(Tariff), 
    BinService = list_to_binary(Service), 
    <<
        <<"<?xml version=\"1.0\" encoding=\"utf-8\"?>\n">>/binary,
        (build_header(BinId, BinTariff, BinService))/binary,
        <<"<sn>">>/binary, SrcAddr/binary, <<"</sn>">>/binary,
        <<"<sin>">>/binary, DestAddr/binary, <<"</sin>">>/binary,
        (build_body(Msg))/binary,
        <<"</message>">>/binary
    >>.

parse_response(Bin) when is_binary(Bin) ->
    Bin1 = skip_declaration(Bin),
    {Tag, Rest} = tag(Bin1),
    <<>> = trim_head(Rest),
    decode(Tag).

%% internal
build_header(Id, Tariff, Service) ->
    <<
        <<"<message ">>/binary,
            <<"mid=\"">>/binary,    Id/binary,      <<"\" ">>/binary, 
            <<"paid=\"">>/binary,   Tariff/binary,  <<"\" ">>/binary, 
            <<"bearer=\"">>/binary, Service/binary, <<"\" ">>/binary,
        <<">">>/binary
    >>.

build_body(Msg) ->
    <<
        <<"<body content-type=\"text/plain\">">>/binary, 
            Msg/binary, 
        <<"</body>">>/binary
    >>.

decode({<<"report">>,_, Rest}) ->
    {<<"status">>, Attrs, [Status]} = lists:keyfind(<<"status">>, 1, Rest),
    ErrorCode = proplists:get_value(<<"errorCode">>, Attrs),
    Desc = proplists:get_value(<<"error">>, Attrs),
    case {ErrorCode, Status, Desc} of
        {<<"0">>, <<"Accepted">>, _} ->
            ok;
        {ErrCode, _, Desc} when ErrCode =:= <<"6">>; ErrCode =:= <<"18">> ->
            rinv_src_addr;
        {<<"19">>, _, Desc} ->
            rinv_dst_addr;
        {ErrCode, _, Desc} when ErrCode =:= <<"15">>; ErrCode =:= <<"26">> ->
            throttled;
        {_ErrCode, _, Desc} ->
            submit_fail
    end;
decode({<<"message">>, AttList, Data}=Report) ->
    case lists:keyfind(<<"service">>, 1, Data) of
        {<<"service">>,_,[<<"delivery-report">>]} ->
            handle_delivered_report(AttList, Data);
	    {<<"service">>,_,[<<"content-request">>]} ->
	        handle_incoming_msg(AttList, Data);
	    false ->
            {error_report, Report}
    end;
decode(Report) ->
    {error_report, Report}.

handle_incoming_msg(AttList, Data) ->
    {<<"rid">>, MsgId} = lists:keyfind(<<"rid">>, 1, AttList),
    {<<"status">>, StatusAttrList, _} = lists:keyfind(<<"status">>, 1, Data),
    {<<"date">>, Date} = lists:keyfind(<<"date">>, 1, StatusAttrList),
    {<<"sn">>,_, [SrcAddr]} = lists:keyfind(<<"sn">>, 1, Data),
    {<<"sin">>,_, [DestAddr]} = lists:keyfind(<<"sin">>, 1, Data),
    {<<"body">>,_, [Msg]} = lists:keyfind(<<"body">>, 1, Data),
    DoneDate = capture_date(Date),
    {incoming_message, MsgId, SrcAddr, DestAddr, Msg, DoneDate}.

handle_delivered_report(AttrList, Data) ->
    {<<"status">>, StatusAttrList, [Status]} = lists:keyfind(<<"status">>, 1, Data),
    {<<"mid">>, Id} = lists:keyfind(<<"mid">>, 1, AttrList),
    {<<"date">>, Date} = lists:keyfind(<<"date">>, 1, StatusAttrList),
    Desc = proplists:get_value(<<"error">>, StatusAttrList),
    DoneDate = capture_date(Date),
    case {Desc, Status} of
        {Desc, <<"Delivered">>} ->
            {delivery_report, delivered, Id, DoneDate, Desc};
        {Desc, _} ->
            {delivery_report, not_delivered, Id, DoneDate, Desc}
    end.	    

%Example: "Wed, 19 Jun 2013 16:17:00 GMT"
capture_date(<<_WeekDay:3/binary,", ",
        BDay:2/binary," ",BMonthName:3/binary," ",BYear:4/binary," ",
        BHour:2/binary,":",BMin:2/binary,":",BSec:2/binary," ",TZR/binary>>) ->
    Year = list_to_integer(binary_to_list(BYear)),
    Month = month_name_to_number(BMonthName),
    Day = list_to_integer(binary_to_list(BDay)),
    Hour = list_to_integer(binary_to_list(BHour)),
    Min = list_to_integer(binary_to_list(BMin)),
    Sec = list_to_integer(binary_to_list(BSec)),
    time_to_local_time({{Year, Month, Day}, {Hour, Min, Sec}}, TZR).
 
time_to_local_time(DateTime, <<"GMT">>) ->
    calendar:universal_time_to_local_time(DateTime);
time_to_local_time(DateTime, <<Sign:8, HH:2/binary, $:, MM:2/binary>>) ->
    H = list_to_integer(binary_to_list(HH)),
    M = list_to_integer(binary_to_list(MM)),
    TimeZoneShiftSeconds = calendar:time_to_seconds({H, M, 0}),
    DateTimeSeconds = calendar:datetime_to_gregorian_seconds(DateTime),
    LocalDateTimeSeconds = case Sign of
        $+ -> DateTimeSeconds + TimeZoneShiftSeconds;
        $- -> DateTimeSeconds - TimeZoneShiftSeconds
    end,
    calendar:gregorian_seconds_to_datetime(LocalDateTimeSeconds).

month_name_to_number(<<"Jan">>) -> 1;
month_name_to_number(<<"Feb">>) -> 2;
month_name_to_number(<<"Mar">>) -> 3;
month_name_to_number(<<"Apr">>) -> 4;
month_name_to_number(<<"May">>) -> 5;
month_name_to_number(<<"Jun">>) -> 6;
month_name_to_number(<<"Jul">>) -> 7;
month_name_to_number(<<"Aug">>) -> 8;
month_name_to_number(<<"Sep">>) -> 9;
month_name_to_number(<<"Oct">>) -> 10;
month_name_to_number(<<"Nov">>) -> 11;
month_name_to_number(<<"Dec">>) -> 12.

skip_declaration(<<"<?xml", Bin/binary>>) ->
    [_,Rest] = binary:split(Bin, <<"?>">>),
    trim_head(Rest),
    skip_declaration(Rest);
skip_declaration(<<"<!", Bin/binary>>) ->
	[_,Rest] = binary:split(Bin, <<">">>),
	trim_head(Rest);
skip_declaration(<<"<",_/binary>> = Bin) -> Bin;
skip_declaration(<<_,Bin/binary>>) -> skip_declaration(Bin).

trim_head(<<" ",Bin/binary>>) -> trim_head(Bin);
trim_head(<<"\n",Bin/binary>>) -> trim_head(Bin);
trim_head(<<"\t",Bin/binary>>) -> trim_head(Bin);
trim_head(<<"\r",Bin/binary>>) -> trim_head(Bin);
trim_head(Bin) -> Bin.

trim_tail(<<>>) ->
    <<>>;
trim_tail(Bin) when is_binary(Bin) ->
    trim_tail(Bin, binary_part(Bin,{0, byte_size(Bin)-1})).

trim_tail(Bin, Rest) when Bin =:= <<Rest/binary, " ">> -> trim_tail(Rest);
trim_tail(Bin, Rest) when Bin =:= <<Rest/binary, "\n">> -> trim_tail(Rest);
trim_tail(Bin, Rest) when Bin =:= <<Rest/binary, "\t">> -> trim_tail(Rest);
trim_tail(Bin, Rest) when Bin =:= <<Rest/binary, "\r">> -> trim_tail(Rest);
trim_tail(Bin, _) -> Bin.

tag(<<"<", Bin/binary>>) ->
    [TagHeader1,Rest1] = binary:split(Bin, <<">">>),
    Len = size(TagHeader1)-1,
    case TagHeader1 of
        <<TagHeader:Len/binary, "/">> ->
            {Tag, Attrs} = tag_header(TagHeader),
            {{Tag,Attrs,[]}, Rest1};
        TagHeader ->
            {Tag, Attrs} = tag_header(TagHeader),
            {Content, Rest2} = tag_content(Rest1, Tag),
            {{Tag,Attrs,Content}, Rest2}
    end.

tag_header(TagHeader) ->
    case binary:split(TagHeader, [<<" ">>]) of
        [Tag] -> {Tag, []};
        [Tag,Attrs] -> {Tag, tag_attrs(Attrs)}
    end.

tag_attrs(<<Blank,Attrs/binary>>) 
  when Blank == $  orelse Blank == $\n orelse Blank == $\t -> 
    tag_attrs(Attrs);
tag_attrs(<<>>) -> [];
tag_attrs(Attrs) ->
    case binary:split(Attrs,<<"=">>) of
        [Key1,Value1] ->
            [Value2,Rest] = attr_value(Value1),
            [{trim_tail(Key1),Value2}|tag_attrs(Rest)]
  end.

attr_value(<<Blank,Value/binary>>)
  when Blank == $  orelse Blank == $\n orelse Blank == $\t ->
    attr_value(Value);
attr_value(<<>>) -> <<>>;
attr_value(<<Quote:1/binary,Value1/binary>>) when Quote == <<"\"">> orelse Quote == <<"'">> ->
    binary:split(Value1,Quote).

tag_content(<<Blank,Bin/binary>>, Parent) 
  when Blank == $  orelse Blank == $\n orelse Blank == $\r orelse Blank == $\t ->
    tag_content(Bin, Parent);

tag_content(<<"</", Bin1/binary>>, Parent) ->
    Len = size(Parent),
    <<Parent:Len/binary, ">", Bin/binary>> = Bin1,
    {[<<>>], Bin};
tag_content(<<"<",_/binary>> = Bin, Parent) ->
    {Tag, Rest1} = tag(Bin),
    {Content, Rest2} = tag_content(Rest1, Parent),
    {[Tag|Content], Rest2};
tag_content(Bin, Parent) ->
    [Text, Rest] = binary:split(Bin, <<"</",Parent/binary,">">>),
    {[Text],Rest}.
