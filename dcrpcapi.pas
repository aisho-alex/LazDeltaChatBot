unit dcrpcapi;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, dcrpc, dcjson, dctypes, dctransport;

type
  TAccountIdArray = array of TAccountId;
  TMsgIdArray = array of TMsgId;

  TEventResult = record
    AccId: TAccountId;
    Event: TJSONData;
  end;

  TDCClient = class
  private
    FRpc: TRpc;
  public
    constructor Create(ATransport: TDCTransport);
    destructor Destroy; override;
    function GetSystemInfo: TJSONObject;
    function GetAllAccountIds: TAccountIdArray;
    function AddAccount: TAccountId;
    function IsConfigured(AccId: TAccountId): Boolean;
    procedure BatchSetConfig(AccId: TAccountId; const Keys: array of string; const Vals: array of TOptionString);
    procedure Configure(AccId: TAccountId);
    function GetConfig(AccId: TAccountId; const Key: string): TOptionString;
    procedure StartIoForAllAccounts;
    function GetNextEvent: TEventResult;
    function GetNextMsgs(AccId: TAccountId): TMsgIdArray;
    procedure SetConfig(AccId: TAccountId; const Key: string; const Val: TOptionString);
    function GetMessage(AccId: TAccountId; MsgId: TMsgId): TMsgSnapshot;
    function MiscSendTextMessage(AccId: TAccountId; ChatId: TChatId; const Text: string): TMsgId;
    { Send a message that may carry a file (7-argument RPC):
      misc_send_msg(accountId, chatId, text, file, filename, location, quotedMessageId).
      Empty strings are sent as JSON null; QuotedId = 0 means "no quote". }
    function MiscSendMsg(AccId: TAccountId; ChatId: TChatId;
      const Text, FilePath, FileName: string; QuotedId: TMsgId): TMsgId;
    { Ask the core to fetch the full message (attachments of a not-yet-downloaded
      message). The download itself is asynchronous: after this call the file
      shows up in Message.file after a while, so poll GetMessage. }
    procedure DownloadFullMessage(AccId: TAccountId; MsgId: TMsgId);
    { SecureJoin (штатное приглашение Delta Chat). Ядро проверяет приглашение,
      запускает рукопожатие В ФОНЕ и сразу возвращает id чата, в который идёт
      вход. Результат (verified-контакт, шифрование) появляется позже сам. }
    function SecureJoin(AccId: TAccountId; const Qr: string): TChatId;
    property Rpc: TRpc read FRpc;
  end;

  function GetAccount(Client: TDCClient): TAccountId;

implementation

{ Tolerant JSON string extraction. deltachat-rpc-server returns these fields as
  a plain string ("done"), JSON null, a number, or an enum-like object such as
  viewType=Image / kind=Downloading; none of those may crash the bot — a crash
  here would kill the core connection. }
function JsonSafeStr(D: TJSONData): string;
var
  O: TJSONObject;
  Sub: TJSONData;
begin
  Result := '';
  if not Assigned(D) or (D is TJSONNull) then Exit;
  if D is TJSONString then
    Result := D.AsString
  else if D is TJSONObject then
  begin
    O := D as TJSONObject;
    Sub := O.Find('viewType');
    if not Assigned(Sub) then Sub := O.Find('kind');
    if not Assigned(Sub) then Sub := O.Find('type');
    if Assigned(Sub) then
      Result := JsonSafeStr(Sub)
    else
      Result := D.AsJSON;
  end
  else
    Result := D.AsString;
end;

{ Optional RPC argument: '' becomes JSON null, otherwise a JSON string. }
function OptStr(const S: string): TJSONData;
begin
  if S = '' then
    Result := TJSONNull.Create
  else
    Result := TJSONString.Create(S);
end;

{ MsgId из ответа ядра. Отвечать оно может по-разному: числом, массивом id
  или объектом с полем msgId/id. Раньше мы жёстко брали AsQWord, и на массиве
  падал разбор ответа misc_send_msg: вложение при этом уже уходило в чат, а в
  журнал писалось «cannot send attachment … Cannot convert data from array
  value» — то есть ошибка врала про потерянное вложение. }
function JsonToMsgId(D: TJSONData): TMsgId;
var
  Arr: TJSONArray;
  Obj: TJSONObject;
  Sub: TJSONData;
begin
  Result := 0;
  if not Assigned(D) or (D is TJSONNull) then Exit;
  if D is TJSONArray then
  begin
    Arr := D as TJSONArray;
    if Arr.Count > 0 then
      Result := JsonToMsgId(Arr.Items[0]);
    Exit;
  end;
  if D is TJSONObject then
  begin
    Obj := D as TJSONObject;
    Sub := Obj.Find('msgId');
    if not Assigned(Sub) then Sub := Obj.Find('id');
    if Assigned(Sub) then
      Result := JsonToMsgId(Sub);
    Exit;
  end;
  try
    Result := D.AsQWord;
  except
    on E: Exception do
      Result := 0;
  end;
end;

function GetAccount(Client: TDCClient): TAccountId;
var
  Ids: TAccountIdArray;
begin
  Ids := Client.GetAllAccountIds;
  if Length(Ids) = 0 then
    Result := Client.AddAccount
  else
    Result := Ids[0];
end;

constructor TDCClient.Create(ATransport: TDCTransport);
begin
  inherited Create;
  FRpc := TRpc.Create(ATransport);
end;

destructor TDCClient.Destroy;
begin
  FRpc.Free;
  inherited Destroy;
end;

function TDCClient.GetSystemInfo: TJSONObject;
var
  Res: TJSONData;
begin
  Res := FRpc.CallResult('get_system_info', TJSONArray.Create);
  Result := Res as TJSONObject;
end;

function TDCClient.GetAllAccountIds: TAccountIdArray;
var
  Res: TJSONData;
  Arr: TJSONArray;
  i: Integer;
begin
  Res := FRpc.CallResult('get_all_account_ids', TJSONArray.Create);
  Arr := Res as TJSONArray;
  SetLength(Result, Arr.Count);
  for i := 0 to Arr.Count - 1 do
    Result[i] := Arr.Items[i].AsQWord;
  Res.Free;
end;

function TDCClient.AddAccount: TAccountId;
var
  Res: TJSONData;
begin
  Res := FRpc.CallResult('add_account', TJSONArray.Create);
  Result := Res.AsQWord;
  Res.Free;
end;

function TDCClient.IsConfigured(AccId: TAccountId): Boolean;
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Res := FRpc.CallResult('is_configured', Params);
  Result := Res.AsBoolean;
  Res.Free;
end;

procedure TDCClient.BatchSetConfig(AccId: TAccountId; const Keys: array of string; const Vals: array of TOptionString);
var
  Params: TJSONArray;
  ConfigObj: TJSONObject;
  i: Integer;
begin
  ConfigObj := TJSONObject.Create;
  for i := Low(Keys) to High(Keys) do
    ConfigObj.Add(Keys[i], dcjson.OptionToJSON(Vals[i]));
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(ConfigObj);
  FRpc.Call('batch_set_config', Params);
end;

procedure TDCClient.Configure(AccId: TAccountId);
var
  Params: TJSONArray;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  FRpc.Call('configure', Params);
end;

function TDCClient.GetConfig(AccId: TAccountId; const Key: string): TOptionString;
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(Key);
  Res := FRpc.CallResult('get_config', Params);
  Result := JSONToOption(Res);
  Res.Free;
end;

procedure TDCClient.StartIoForAllAccounts;
begin
  FRpc.Call('start_io_for_all_accounts', TJSONArray.Create);
end;

function TDCClient.GetNextEvent: TEventResult;
var
  Params: TJSONArray;
  Res: TJSONData;
  Obj: TJSONObject;
  EvData: TJSONData;
begin
  Params := TJSONArray.Create;
  Res := FRpc.CallResult('get_next_event', Params);
  Obj := Res as TJSONObject;
  Result.AccId := Obj.Elements['contextId'].AsQWord;
  EvData := Obj.Find('event');
  if Assigned(EvData) then
    Result.Event := EvData.Clone
  else
    Result.Event := nil;
  Res.Free;
end;

function TDCClient.GetNextMsgs(AccId: TAccountId): TMsgIdArray;
var
  Params: TJSONArray;
  Res: TJSONData;
  Arr: TJSONArray;
  i: Integer;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Res := FRpc.CallResult('get_next_msgs', Params);
  Arr := Res as TJSONArray;
  SetLength(Result, Arr.Count);
  for i := 0 to Arr.Count - 1 do
    Result[i] := Arr.Items[i].AsQWord;
  Res.Free;
end;

procedure TDCClient.SetConfig(AccId: TAccountId; const Key: string; const Val: TOptionString);
var
  Params: TJSONArray;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(Key);
  Params.Add(dcjson.OptionToJSON(Val));
  FRpc.Call('set_config', Params);
end;

function TDCClient.GetMessage(AccId: TAccountId; MsgId: TMsgId): TMsgSnapshot;
var
  Params: TJSONArray;
  Res: TJSONData;
  Obj: TJSONObject;
  D: TJSONData;
begin
  Result := Default(TMsgSnapshot);
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(MsgId);
  Res := FRpc.CallResult('get_message', Params);
  Obj := Res as TJSONObject;
  D := Obj.Find('id');
  if Assigned(D) then Result.Id := D.AsQWord else Result.Id := 0;
  D := Obj.Find('chatId');
  if Assigned(D) then Result.ChatId := D.AsQWord else Result.ChatId := 0;
  D := Obj.Find('fromId');
  if Assigned(D) then Result.FromId := D.AsQWord else Result.FromId := 0;
  D := Obj.Find('text');
  if Assigned(D) and not (D is TJSONNull) then Result.Text := D.AsString else Result.Text := '';
  D := Obj.Find('isBot');
  if Assigned(D) then Result.IsBot := D.AsBoolean else Result.IsBot := False;
  D := Obj.Find('isInfo');
  if Assigned(D) then Result.IsInfo := D.AsBoolean else Result.IsInfo := False;
  // --- attachments ---
  D := Obj.Find('file');
  if Assigned(D) and not (D is TJSONNull) then Result.FilePath := D.AsString;
  D := Obj.Find('fileName');
  if Assigned(D) and not (D is TJSONNull) then Result.FileName := D.AsString;
  D := Obj.Find('fileMime');
  if Assigned(D) and not (D is TJSONNull) then Result.FileMime := D.AsString;
  D := Obj.Find('fileBytes');
  if Assigned(D) and not (D is TJSONNull) then Result.FileBytes := D.AsInt64;
  Result.ViewType := JsonSafeStr(Obj.Find('viewType'));
  Result.DownloadState := JsonSafeStr(Obj.Find('downloadState'));
  Res.Free;
end;

function TDCClient.MiscSendTextMessage(AccId: TAccountId; ChatId: TChatId; const Text: string): TMsgId;
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(ChatId);
  Params.Add(Text);
  Res := FRpc.CallResult('misc_send_text_message', Params);
  Result := JsonToMsgId(Res);
  Res.Free;
end;

function TDCClient.SecureJoin(AccId: TAccountId; const Qr: string): TChatId;
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(Qr);
  Res := FRpc.CallResult('secure_join', Params);
  Result := JsonToMsgId(Res);
  Res.Free;
end;

function TDCClient.MiscSendMsg(AccId: TAccountId; ChatId: TChatId;
  const Text, FilePath, FileName: string; QuotedId: TMsgId): TMsgId;
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(ChatId);
  Params.Add(OptStr(Text));
  Params.Add(OptStr(FilePath));
  Params.Add(OptStr(FileName));
  Params.Add(TJSONNull.Create);          // location (unused)
  if QuotedId > 0 then
    Params.Add(QuotedId)
  else
    Params.Add(TJSONNull.Create);
  Res := FRpc.CallResult('misc_send_msg', Params);
  Result := JsonToMsgId(Res);
  Res.Free;
end;

procedure TDCClient.DownloadFullMessage(AccId: TAccountId; MsgId: TMsgId);
var
  Params: TJSONArray;
  Res: TJSONData;
begin
  Params := TJSONArray.Create;
  Params.Add(AccId);
  Params.Add(MsgId);
  Res := FRpc.CallResult('download_full_message', Params);
  Res.Free;
end;

end.
