unit dcbot;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, dcrpcapi, dcevents, dctypes, dcjson, fpjson, fpjsonrtti;

type
  TEventHandler = procedure(AccId: TAccountId; const Ev: TDCEvent);
  TNewMsgHandler = procedure(AccId: TAccountId; MsgId: TMsgId);

  TDCBot = class
  private
    FClient: TDCClient;
    FOnInfo: TEventHandler;
    FOnWarning: TEventHandler;
    FOnError: TEventHandler;
    FOnNewMsg: TNewMsgHandler;
    procedure DispatchEvent(AccId: TAccountId; const Ev: TDCEvent);
    procedure ProcessMessages(AccId: TAccountId);
  public
    constructor Create(AClient: TDCClient);
    procedure OnInfo(Handler: TEventHandler);
    procedure OnWarning(Handler: TEventHandler);
    procedure OnError(Handler: TEventHandler);
    procedure OnNewMsg(Handler: TNewMsgHandler);
    procedure Configure(AccId: TAccountId; const Addr, Pw: string);
    procedure Run;
  end;

implementation

constructor TDCBot.Create(AClient: TDCClient);
begin
  inherited Create;
  FClient := AClient;
end;

procedure TDCBot.OnInfo(Handler: TEventHandler);
begin
  FOnInfo := Handler;
end;

procedure TDCBot.OnWarning(Handler: TEventHandler);
begin
  FOnWarning := Handler;
end;

procedure TDCBot.OnError(Handler: TEventHandler);
begin
  FOnError := Handler;
end;

procedure TDCBot.OnNewMsg(Handler: TNewMsgHandler);
begin
  FOnNewMsg := Handler;
end;

procedure TDCBot.DispatchEvent(AccId: TAccountId; const Ev: TDCEvent);
begin
  case Ev.Kind of
    ekInfo:
      if Assigned(FOnInfo) then FOnInfo(AccId, Ev);
    ekWarning:
      if Assigned(FOnWarning) then FOnWarning(AccId, Ev);
    ekError:
      if Assigned(FOnError) then FOnError(AccId, Ev);
  end;
end;

procedure TDCBot.Configure(AccId: TAccountId; const Addr, Pw: string);
var
  Keys: array of string;
  Vals: array of TOptionString;
  V: string;

  procedure Add(const Key, EnvVar: string);
  begin
    V := GetEnvironmentVariable(EnvVar);
    if V <> '' then
    begin
      SetLength(Keys, Length(Keys)+1);
      SetLength(Vals, Length(Vals)+1);
      Keys[High(Keys)] := Key;
      Vals[High(Vals)] := SomeStr(V);
    end;
  end;

begin
  SetLength(Keys, 3);
  SetLength(Vals, 3);
  Keys[0] := 'bot';     Vals[0] := SomeStr('1');
  Keys[1] := 'addr';    Vals[1] := SomeStr(Addr);
  Keys[2] := 'mail_pw'; Vals[2] := SomeStr(Pw);
  // Optional explicit IMAP/SMTP overrides via env vars
  Add('mail_server', 'MAIL_SERVER');
  Add('mail_port',   'MAIL_PORT');
  Add('mail_user',   'MAIL_USER');
  Add('send_server', 'SEND_SERVER');
  Add('send_port',   'SEND_PORT');
  Add('send_user',   'SEND_USER');
  Add('send_pw',     'SEND_PW');
  FClient.BatchSetConfig(AccId, Keys, Vals);
  FClient.Configure(AccId);
end;

procedure TDCBot.ProcessMessages(AccId: TAccountId);
var
  MsgIds: array of TMsgId;
  i: Integer;
begin
  MsgIds := FClient.GetNextMsgs(AccId);
  for i := Low(MsgIds) to High(MsgIds) do
  begin
    FClient.SetConfig(AccId, 'last_msg_id', SomeStr(IntToStr(MsgIds[i])));
    if Assigned(FOnNewMsg) then
      FOnNewMsg(AccId, MsgIds[i]);
  end;
end;

procedure TDCBot.Run;
var
  AccIds: array of TAccountId;
  i: Integer;
  EvRes: TEventResult;
  Ev: TDCEvent;
begin
  FClient.StartIoForAllAccounts;
  AccIds := FClient.GetAllAccountIds;
  for i := Low(AccIds) to High(AccIds) do
    if FClient.IsConfigured(AccIds[i]) then
      ProcessMessages(AccIds[i]);
  while True do
  begin
    EvRes := FClient.GetNextEvent;
    Ev := ParseEvent(EvRes.Event);
    if (Ev.Kind = ekIncomingMsg) or (Ev.Kind = ekMsgsChanged) then
    begin
      WriteLn('DEBUG event acc=', EvRes.AccId, ' kind=', Ord(Ev.Kind), ' chatId=', Ev.ChatId, ' msgId=', Ev.MsgId);
      Flush(Output);
    end;
    DispatchEvent(EvRes.AccId, Ev);
    if (Ev.Kind = ekIncomingMsg) or (Ev.Kind = ekMsgsChanged) then
      ProcessMessages(EvRes.AccId);
    EvRes.Event.Free;
  end;
end;

end.
