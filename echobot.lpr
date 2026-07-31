program EchoBot;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  SysUtils,
  dctransport,
  dcrpcapi,
  dcbot,
  dctypes,
  dcevents,
  dcjson,
  fpjson;

var
  Transport: TDCTransport;
  Client: TDCClient;
  Bot: TDCBot;
  AccId: TAccountId;
  SysInfo: TJSONObject;
  AddrOpt: TOptionString;

procedure LogEvent(AccId: TAccountId; const Ev: TDCEvent);
begin
  case Ev.Kind of
    ekInfo:    WriteLn('INFO: ' + Ev.Msg);
    ekWarning: WriteLn('WARN: ' + Ev.Msg);
    ekError:   WriteLn('ERROR: ' + Ev.Msg);
  end;
end;

procedure HandleNewMsg(AccId: TAccountId; MsgId: TMsgId);
var
  Snap: TMsgSnapshot;
  Text: string;
begin
  Snap := Client.GetMessage(AccId, MsgId);
  WriteLn(Format('DEBUG msg id=%d chat=%d from=%d isBot=%s isInfo=%s text="%s"',
    [Snap.Id, Snap.ChatId, Snap.FromId,
     BoolToStr(Snap.IsBot, True), BoolToStr(Snap.IsInfo, True),
     Snap.Text]));
  if Snap.FromId > ContactLastSpecial then
  begin
    Text := Trim(Snap.Text);
    if Text = '/start' then
    begin
      WriteLn('DEBUG replying with "работаю" to /start');
      Client.MiscSendTextMessage(AccId, Snap.ChatId, 'работаю');
    end;
  end;
end;

begin
  Transport := TDCTransport.Create;
  Transport.Open;
  Client := TDCClient.Create(Transport);
  Bot := TDCBot.Create(Client);

  AccId := GetAccount(Client);

  SysInfo := Client.GetSystemInfo;
  WriteLn('Running deltachat core ' + SysInfo.Find('deltachat_core_version').AsString);
  SysInfo.Free;

  Bot.OnInfo(@LogEvent);
  Bot.OnWarning(@LogEvent);
  Bot.OnError(@LogEvent);
  Bot.OnNewMsg(@HandleNewMsg);

  if not Client.IsConfigured(AccId) then
  begin
    if ParamCount < 2 then
    begin
      WriteLn('Usage: ' + ExtractFileName(ParamStr(0)) + ' <addr> <password>');
      Halt(1);
    end;
    Bot.Configure(AccId, ParamStr(1), ParamStr(2));
  end;

  AddrOpt := Client.GetConfig(AccId, 'configured_addr');
  if AddrOpt.HasValue then
    WriteLn('Listening at: ' + AddrOpt.Value);

  Bot.Run;

  Bot.Free;
  Client.Free;
  Transport.Close;
  Transport.Free;
end.
