unit dcllm;

{ LLM client for the echo bot.
  Speaks the OpenAI-compatible /v1/chat/completions protocol over HTTPS
  (fphttpclient + opensslsockets), so it works against any provider that
  exposes that wire format: neuraldeep Hub, Drift, a local Hermes
  gateway api_server, etc. The backend is selected purely via env vars.

  Env vars:
    LLM_BASE_URL   base URL, default https://api.neuraldeep.ru/v1
    LLM_API_KEY    Bearer token (sk-* / dft_* / API_SERVER_KEY); empty = disabled
    LLM_MODEL      default gpt-oss-120b
    LLM_SYSTEM     system prompt; default is a short Russian assistant prompt
    LLM_TIMEOUT    connect+IO timeout in seconds, default 120
    LLM_MAX_TOKENS default 1024
    LLM_TEMPERATURE default 0.2
    LLM_HISTORY    max messages kept per chat, default 20
    LLM_HISTORY_DIR directory for per-chat history files (chatId.json),
                    default 'history' (relative to CWD). History is persisted
                    after every successful exchange and reloaded on startup,
                    so conversations survive bot restarts.
    LLM_RETRIES    extra attempts on 429 / network errors, default 2
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, jsonparser, fphttpclient, opensslsockets, fgl;

type
  TLLMConfig = record
    BaseURL: string;
    ApiKey: string;
    Model: string;
    SystemPrompt: string;
    TimeoutSec: Integer;
    MaxTokens: Integer;
    Temperature: Double;
    HistoryLen: Integer;
    HistoryDir: string;
    Retries: Integer;
  end;

  TDCLLM = class
  private
    FConfig: TLLMConfig;
    FHistory: specialize TFPGMap<UInt64, TJSONArray>; // chatId -> message objects
    function BuildRequestBody(ChatId: UInt64; const UserText: string): string;
    function DoPost(const Body: string): string;
    function RetryDelayMs(Client: TFPHTTPClient): Integer;
    function HistoryPath(ChatId: UInt64): string;
    procedure EnsureChat(ChatId: UInt64);
    procedure LoadHistory(ChatId: UInt64);
    procedure SaveHistory(ChatId: UInt64);
    procedure AppendMessage(ChatId: UInt64; const Role, Content: string);
    procedure TrimHistory(ChatId: UInt64);
  public
    constructor Create;
    destructor Destroy; override;
    function IsConfigured: Boolean;
    property Model: string read FConfig.Model;
    property BaseURL: string read FConfig.BaseURL;
    property HistoryDir: string read FConfig.HistoryDir;
    { Sends UserText (plus per-chat history) to the LLM and returns the
      assistant reply. Raises on failure. History is updated only on success. }
    function Complete(ChatId: UInt64; const UserText: string): string;
  end;

implementation

const
  DefaultBaseURL = 'https://api.neuraldeep.ru/v1';
  DefaultModel   = 'gpt-oss-120b';
  DefaultSystem  = 'Ты — ассистент в Delta Chat. Отвечай кратко и по делу, по-русски.';

function GetEnvInt(const Name: string; Default: Integer): Integer;
var
  S: string;
begin
  S := GetEnvironmentVariable(Name);
  if S = '' then
    Result := Default
  else
    Result := StrToIntDef(S, Default);
end;

function GetEnvFloat(const Name: string; Default: Double): Double;
var
  S: string;
begin
  S := GetEnvironmentVariable(Name);
  if S = '' then
    Result := Default
  else
    Result := StrToFloatDef(S, Default);
end;

constructor TDCLLM.Create;
begin
  inherited Create;
  FConfig.BaseURL      := GetEnvironmentVariable('LLM_BASE_URL');
  if FConfig.BaseURL = '' then FConfig.BaseURL := DefaultBaseURL;
  FConfig.ApiKey       := GetEnvironmentVariable('LLM_API_KEY');
  FConfig.Model        := GetEnvironmentVariable('LLM_MODEL');
  if FConfig.Model = '' then FConfig.Model := DefaultModel;
  FConfig.SystemPrompt := GetEnvironmentVariable('LLM_SYSTEM');
  if FConfig.SystemPrompt = '' then FConfig.SystemPrompt := DefaultSystem;
  FConfig.TimeoutSec   := GetEnvInt('LLM_TIMEOUT', 120);
  FConfig.MaxTokens    := GetEnvInt('LLM_MAX_TOKENS', 1024);
  FConfig.Temperature  := GetEnvFloat('LLM_TEMPERATURE', 0.2);
  FConfig.HistoryLen   := GetEnvInt('LLM_HISTORY', 20);
  FConfig.HistoryDir   := GetEnvironmentVariable('LLM_HISTORY_DIR');
  if FConfig.HistoryDir = '' then FConfig.HistoryDir := 'history';
  FConfig.Retries      := GetEnvInt('LLM_RETRIES', 2);
  FHistory := specialize TFPGMap<UInt64, TJSONArray>.Create;
end;

destructor TDCLLM.Destroy;
var
  i: Integer;
begin
  for i := 0 to FHistory.Count - 1 do
    FHistory.Data[i].Free;
  FHistory.Free;
  inherited Destroy;
end;

function TDCLLM.IsConfigured: Boolean;
begin
  Result := FConfig.ApiKey <> '';
end;

procedure TDCLLM.EnsureChat(ChatId: UInt64);
begin
  if FHistory.IndexOf(ChatId) < 0 then
  begin
    FHistory.Add(ChatId, TJSONArray.Create);
    LoadHistory(ChatId);
  end;
end;

function TDCLLM.HistoryPath(ChatId: UInt64): string;
begin
  Result := IncludeTrailingPathDelimiter(FConfig.HistoryDir) + IntToStr(ChatId) + '.json';
end;

procedure TDCLLM.LoadHistory(ChatId: UInt64);
var
  P: string;
  FS: TFileStream;
  J: TJSONData;
  Arr: TJSONArray;
begin
  P := HistoryPath(ChatId);
  if not FileExists(P) then Exit;
  try
    FS := TFileStream.Create(P, fmOpenRead or fmShareDenyWrite);
    try
      J := GetJSON(FS);
    finally
      FS.Free;
    end;
    try
      if J is TJSONArray then
      begin
        Arr := (J as TJSONArray).Clone as TJSONArray;
        while Arr.Count > FConfig.HistoryLen do
          Arr.Delete(0);
        FHistory[ChatId].Free;
        FHistory[ChatId] := Arr;
        WriteLn(Format('DEBUG history loaded for chat %d: %d messages', [ChatId, Arr.Count]));
      end
      else
        WriteLn(StdErr, Format('WARN: history file %s is not a JSON array, ignoring', [P]));
    finally
      J.Free; // frees the original, the clone lives in FHistory
    end;
  except
    on E: Exception do
      WriteLn(StdErr, Format('WARN: cannot load history for chat %d from %s: %s', [ChatId, P, E.Message]));
  end;
end;

procedure TDCLLM.SaveHistory(ChatId: UInt64);
var
  Dir, P, PTmp, S: string;
  FS: TFileStream;
begin
  try
    Dir := FConfig.HistoryDir;
    if not DirectoryExists(Dir) then
      if not ForceDirectories(Dir) then
      begin
        WriteLn(StdErr, Format('WARN: cannot create history dir %s', [Dir]));
        Exit;
      end;
    P := HistoryPath(ChatId);
    PTmp := P + '.tmp';
    S := FHistory[ChatId].AsJSON;
    FS := TFileStream.Create(PTmp, fmCreate);
    try
      FS.WriteBuffer(S[1], Length(S));
    finally
      FS.Free;
    end;
    // atomic-ish: rename over the previous file; on POSIX rename() overwrites
    if not RenameFile(PTmp, P) then
      WriteLn(StdErr, Format('WARN: cannot rename %s -> %s', [PTmp, P]));
  except
    on E: Exception do
      WriteLn(StdErr, Format('WARN: cannot save history for chat %d: %s', [ChatId, E.Message]));
  end;
end;

procedure TDCLLM.AppendMessage(ChatId: UInt64; const Role, Content: string);
var
  M: TJSONObject;
begin
  EnsureChat(ChatId);
  M := TJSONObject.Create;
  M.Add('role', Role);
  M.Add('content', Content);
  FHistory[ChatId].Add(M);
  TrimHistory(ChatId);
  SaveHistory(ChatId);
end;

procedure TDCLLM.TrimHistory(ChatId: UInt64);
var
  Arr: TJSONArray;
begin
  Arr := FHistory[ChatId];
  while Arr.Count > FConfig.HistoryLen do
    Arr.Delete(0);
end;

function TDCLLM.BuildRequestBody(ChatId: UInt64; const UserText: string): string;
var
  Obj: TJSONObject;
  Messages: TJSONArray;
  Hist: TJSONArray;
  i: Integer;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('model', FConfig.Model);
    Messages := TJSONArray.Create;
    if FConfig.SystemPrompt <> '' then
    begin
      Messages.Add(TJSONObject.Create(['role', 'system', 'content', FConfig.SystemPrompt]));
    end;
    // make sure the chat entry exists and on-disk history is loaded BEFORE
    // assembling the request (in a fresh process the map is empty)
    EnsureChat(ChatId);
    if FHistory.IndexOf(ChatId) >= 0 then
    begin
      Hist := FHistory[ChatId];
      for i := 0 to Hist.Count - 1 do
        Messages.Add(Hist.Items[i].Clone);
    end;
    Messages.Add(TJSONObject.Create(['role', 'user', 'content', UserText]));
    Obj.Add('messages', Messages);
    Obj.Add('max_tokens', FConfig.MaxTokens);
    Obj.Add('temperature', FConfig.Temperature);
    // session-sticky routing: keep the same upstream worker per chat (KV-cache)
    Obj.Add('user', 'dcbot:' + IntToStr(ChatId));
    Result := Obj.AsJSON;
  finally
    Obj.Free; // frees Messages and all clones
  end;
end;

function TDCLLM.RetryDelayMs(Client: TFPHTTPClient): Integer;
var
  S: string;
  N: Integer;
begin
  Result := 2000;
  S := Client.ResponseHeaders.Values['Retry-After'];
  if S <> '' then
  begin
    N := StrToIntDef(Trim(S), 0);
    if N > 0 then
    begin
      Result := N * 1000;
      if Result > 10000 then Result := 10000; // never sleep longer than 10 s
    end;
  end;
end;

function TDCLLM.DoPost(const Body: string): string;
var
  C: TFPHTTPClient;
  SS: TStringStream;
  Attempt: Integer;
  Status: Integer;
begin
  Result := '';
  for Attempt := 0 to FConfig.Retries do
  begin
    C := TFPHTTPClient.Create(nil);
    SS := nil;
    try
      try
        C.ConnectTimeout := FConfig.TimeoutSec * 1000;
        C.IOTimeout := FConfig.TimeoutSec * 1000;
        C.AllowRedirect := True;
        C.AddHeader('Authorization', 'Bearer ' + FConfig.ApiKey);
        C.AddHeader('Content-Type', 'application/json');
        SS := TStringStream.Create(Body);
        C.RequestBody := SS;
        Result := C.Post(FConfig.BaseURL + '/chat/completions');
        // NOTE: fphttpclient's Post() does NOT raise on 4xx/5xx — it returns
        // the body and exposes ResponseStatusCode, so we check it explicitly.
        Status := C.ResponseStatusCode;
        if (Status >= 200) and (Status < 300) then Break; // success
        if (Status = 429) or (Status >= 500) then
        begin
          if Attempt < FConfig.Retries then
          begin
            WriteLn(StdErr, Format('WARN: LLM HTTP %d, retry %d/%d',
              [Status, Attempt + 1, FConfig.Retries]));
            Sleep(RetryDelayMs(C));
            Continue;
          end;
          raise Exception.CreateFmt('LLM HTTP %d: %s', [Status, Copy(Result, 1, 300)]);
        end;
        // 400/401/403/404... — client errors, no retry
        raise Exception.CreateFmt('LLM HTTP %d: %s', [Status, Copy(Result, 1, 300)]);
      except
        on E: Exception do
        begin
          // network-level errors (connect/read/write) are retryable
          if (Attempt < FConfig.Retries) and (E is EHTTPClientSocket) then
          begin
            WriteLn(StdErr, Format('WARN: LLM network error (%s), retry %d/%d',
              [E.Message, Attempt + 1, FConfig.Retries]));
            Sleep(RetryDelayMs(C));
          end
          else
            raise;
        end;
      end;
    finally
      SS.Free;
      C.Free;
    end;
  end;
end;

function SafeStr(J: TJSONData; const Path: string): string;
var
  D: TJSONData;
begin
  D := J.FindPath(Path);
  if (D <> nil) and not (D is TJSONNull) then
    Result := D.AsString
  else
    Result := 'null';
end;

function TDCLLM.Complete(ChatId: UInt64; const UserText: string): string;
var
  Body: string;
  Resp: string;
  J: TJSONData;
  Ch: TJSONData;
  Content: string;
  FReason: string;
  Attempt: Integer;
begin
  if not IsConfigured then
    raise Exception.Create('LLM not configured: set LLM_API_KEY');
  Body := BuildRequestBody(ChatId, UserText);
  Content := '';
  for Attempt := 0 to 1 do
  begin
    Resp := DoPost(Body);
    J := GetJSON(Resp);
    try
      FReason := SafeStr(J, 'choices[0].finish_reason');
      Ch := J.FindPath('choices[0].message.content');
      if (Ch = nil) or (Ch is TJSONNull) then
        Content := '' // null content -> retry
      else
        Content := Ch.AsString;
    finally
      J.Free;
    end;
    if Content <> '' then Break;
    if Attempt = 0 then
    begin
      // gpt-oss and other reasoning models occasionally return content:null
      // (token budget spent on reasoning or a transient hiccup) — retry once
      WriteLn(StdErr, Format('WARN: LLM returned null/empty content (finish_reason=%s), retrying once', [FReason]));
      Sleep(1000);
    end;
  end;
  if Content = '' then
    raise Exception.Create('LLM returned null/empty content (finish_reason=' + FReason +
      '); increase LLM_MAX_TOKENS; raw: ' + Copy(Resp, 1, 400));
  // history is updated only on success, so a failed call never poisons the context
  AppendMessage(ChatId, 'user', UserText);
  AppendMessage(ChatId, 'assistant', Content);
  Result := Content;
end;

initialization
  // Make every string conversion in this process UTF-8. Without this, on
  // C/POSIX locales RawByteString->AnsiString gets tagged CP1252 and fpjson
  // turns non-ASCII response text into '?', corrupting bot replies.
  SetMultiByteConversionCodePage(CP_UTF8);

end.
