unit dcevents;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

type
  TDCEventKind = (
    ekInfo,
    ekWarning,
    ekError,
    ekIncomingMsg,
    ekMsgsChanged,
    ekOther
  );

  TDCEvent = record
    Kind: TDCEventKind;
    Msg: string;
    ChatId: UInt64;
    MsgId: UInt64;
  end;

function ParseEvent(Json: TJSONData): TDCEvent;

implementation

uses
  sysutils;

function ParseEvent(Json: TJSONData): TDCEvent;
var
  Obj: TJSONObject;
  KindStr: string;
  D: TJSONData;
begin
  Result.Kind := ekOther;
  Result.Msg := '';
  Result.ChatId := 0;
  Result.MsgId := 0;
  if not (Json is TJSONObject) then Exit;
  Obj := Json as TJSONObject;
  D := Obj.Find('kind');
  if Assigned(D) then
    KindStr := D.AsString
  else
    Exit;
  if KindStr='Info' then Result.Kind:=ekInfo
  else if KindStr='Warning' then Result.Kind:=ekWarning
  else if KindStr='Error' then Result.Kind:=ekError
  else if KindStr='IncomingMsg' then Result.Kind:=ekIncomingMsg
  else if KindStr='MsgsChanged' then Result.Kind:=ekMsgsChanged;
  D := Obj.Find('msg');
  if Assigned(D) then Result.Msg := D.AsString;
  D := Obj.Find('chatId');
  if Assigned(D) then Result.ChatId := D.AsQWord;
  D := Obj.Find('msgId');
  if Assigned(D) then Result.MsgId := D.AsQWord;
end;

end.
