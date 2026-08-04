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
    FModelCache: specialize TFPGMap<UInt64, string>;  // chatId -> per-chat model
    FSessionCache: specialize TFPGMap<UInt64, string>; // chatId -> Drift conversation_id
    FIsDrift: Boolean; // backend is Drift (base URL contains 'drift')
    function BuildRequestBody(ChatId: UInt64; const UserText: string): string;
    function DoPost(const Body: string): string;
    function DoRequest(const Method, Url, Body: string; out Status: Integer): string;
    function RetryDelayMs(Client: TFPHTTPClient): Integer;
    function HistoryPath(ChatId: UInt64): string;
    function MetaPath(ChatId: UInt64): string;
    procedure EnsureChat(ChatId: UInt64);
    procedure LoadHistory(ChatId: UInt64);
    procedure SaveHistory(ChatId: UInt64);
    procedure LoadMeta(ChatId: UInt64);
    procedure SaveMeta(ChatId: UInt64);
    procedure AppendMessage(ChatId: UInt64; const Role, Content: string);
    procedure TrimHistory(ChatId: UInt64);
    function ResolveModel(ChatId: UInt64): string;
    function ResolveSession(ChatId: UInt64): string;
    function ModelAvailable(const ModelName: string): Boolean;
  public
    constructor Create;
    destructor Destroy; override;
    function IsConfigured: Boolean;
    property Model: string read FConfig.Model;
    property BaseURL: string read FConfig.BaseURL;
    property HistoryDir: string read FConfig.HistoryDir;
    property IsDrift: Boolean read FIsDrift;
    { Sends UserText (plus per-chat history) to the LLM and returns the
      assistant reply. Raises on failure. History is updated only on success. }
    function Complete(ChatId: UInt64; const UserText: string): string;
    { Current per-chat model (defaults to LLM_MODEL). }
    function ChatModel(ChatId: UInt64): string;
    { Comma-separated model ids from GET /v1/models. Raises on failure. }
    function AvailableModels: string;
    { Sets the per-chat model, validating against /v1/models when the
      provider exposes it. Raises if the model is not in the list. }
    procedure SetModel(ChatId: UInt64; const ModelName: string);
    { Search API (neuraldeep Hub): Kind = 'web' | 'tg' | 'crawl'.
      Returns a human-readable summary of the top results. }
    function Search(const Kind, Query: string): string;
    { Clears the chat context. For Hub backends: wipes the in-memory
      history and deletes the history file. For Drift: creates a NEW
      conversation (new session), since Drift keeps its own memory. }
    procedure ClearContext(ChatId: UInt64);
    { Replaces invalid UTF-8 sequences with '?'. Use before sending any
      user-visible text: deltachat-rpc-server dies on broken UTF-8
      ("stream did not contain valid UTF-8"). }
    function SanitizeUtf8(const S: string): string;
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
  FIsDrift := Pos('drift', LowerCase(FConfig.BaseURL)) > 0;
  FHistory := specialize TFPGMap<UInt64, TJSONArray>.Create;
  FModelCache := specialize TFPGMap<UInt64, string>.Create;
  FSessionCache := specialize TFPGMap<UInt64, string>.Create;
end;

destructor TDCLLM.Destroy;
var
  i: Integer;
begin
  for i := 0 to FHistory.Count - 1 do
    FHistory.Data[i].Free;
  FHistory.Free;
  FModelCache.Free;
  FSessionCache.Free;
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
    LoadMeta(ChatId);
  end;
end;

function TDCLLM.MetaPath(ChatId: UInt64): string;
begin
  Result := IncludeTrailingPathDelimiter(FConfig.HistoryDir) + IntToStr(ChatId) + '.meta';
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

procedure TDCLLM.LoadMeta(ChatId: UInt64);
var
  P: string;
  FS: TFileStream;
  J: TJSONData;
  S: string;
begin
  P := MetaPath(ChatId);
  if not FileExists(P) then Exit;
  try
    FS := TFileStream.Create(P, fmOpenRead or fmShareDenyWrite);
    try
      J := GetJSON(FS);
    finally
      FS.Free;
    end;
    try
      S := SafeStr(J, 'model');
      if (S <> '') and (S <> 'null') then FModelCache[ChatId] := S;
      S := SafeStr(J, 'session');
      if (S <> '') and (S <> 'null') then FSessionCache[ChatId] := S;
    finally
      J.Free;
    end;
  except
    on E: Exception do
      WriteLn(StdErr, Format('WARN: cannot load meta for chat %d from %s: %s', [ChatId, P, E.Message]));
  end;
end;

procedure TDCLLM.SaveMeta(ChatId: UInt64);
var
  Dir, P, PTmp, S: string;
  Obj: TJSONObject;
  FS: TFileStream;
begin
  Obj := TJSONObject.Create;
  try
    if FModelCache.IndexOf(ChatId) >= 0 then
      Obj.Add('model', FModelCache[ChatId]);
    if FSessionCache.IndexOf(ChatId) >= 0 then
      Obj.Add('session', FSessionCache[ChatId]);
    S := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  if S = '{}' then Exit; // nothing to persist
  try
    Dir := FConfig.HistoryDir;
    if not DirectoryExists(Dir) then
      if not ForceDirectories(Dir) then
      begin
        WriteLn(StdErr, Format('WARN: cannot create history dir %s', [Dir]));
        Exit;
      end;
    P := MetaPath(ChatId);
    PTmp := P + '.tmp';
    FS := TFileStream.Create(PTmp, fmCreate);
    try
      FS.WriteBuffer(S[1], Length(S));
    finally
      FS.Free;
    end;
    if not RenameFile(PTmp, P) then
      WriteLn(StdErr, Format('WARN: cannot rename %s -> %s', [PTmp, P]));
  except
    on E: Exception do
      WriteLn(StdErr, Format('WARN: cannot save meta for chat %d: %s', [ChatId, E.Message]));
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
    Obj.Add('model', ResolveModel(ChatId));
    Messages := TJSONArray.Create;
    if FIsDrift then
    begin
      // Drift pulls its own memory from its DB — send only the latest prompt,
      // plus conversation_id to keep the session on the provider side.
      Messages.Add(TJSONObject.Create(['role', 'user', 'content', UserText]));
      Obj.Add('messages', Messages);
      Obj.Add('conversation_id', StrToInt(ResolveSession(ChatId)));
    end
    else
    begin
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
    end;
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

{ Generic HTTP request (GET or POST). Returns the body; Status is set to the
  HTTP status code. fphttpclient does NOT raise on 4xx/5xx. }
function TDCLLM.DoRequest(const Method, Url, Body: string; out Status: Integer): string;
var
  C: TFPHTTPClient;
  SS: TStringStream;
begin
  Result := '';
  Status := 0;
  C := TFPHTTPClient.Create(nil);
  SS := nil;
  try
    C.ConnectTimeout := FConfig.TimeoutSec * 1000;
    C.IOTimeout := FConfig.TimeoutSec * 1000;
    C.AllowRedirect := True;
    C.AddHeader('Authorization', 'Bearer ' + FConfig.ApiKey);
    if Method = 'POST' then
    begin
      C.AddHeader('Content-Type', 'application/json');
      SS := TStringStream.Create(Body);
      C.RequestBody := SS;
      Result := C.Post(Url);
    end
    else
      Result := C.Get(Url);
    Status := C.ResponseStatusCode;
  finally
    SS.Free;
    C.Free;
  end;
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

function TDCLLM.ResolveModel(ChatId: UInt64): string;
begin
  EnsureChat(ChatId); // loads meta into caches
  if FModelCache.IndexOf(ChatId) >= 0 then
    Result := FModelCache[ChatId]
  else
    Result := FConfig.Model;
end;

function TDCLLM.ChatModel(ChatId: UInt64): string;
begin
  Result := ResolveModel(ChatId);
end;

function TDCLLM.AvailableModels: string;
var
  Resp: string;
  J: TJSONData;
  Arr: TJSONArray;
  i: Integer;
  Ids: TStringList;
  Status: Integer;
begin
  Result := '';
  Resp := DoRequest('GET', FConfig.BaseURL + '/models', '', Status);
  if (Status < 200) or (Status >= 300) then
    raise Exception.CreateFmt('GET /models HTTP %d: %s', [Status, Copy(Resp, 1, 200)]);
  J := GetJSON(Resp);
  try
    Arr := J.FindPath('data') as TJSONArray;
    if Arr = nil then
      raise Exception.Create('GET /models: no "data" array in response');
    Ids := TStringList.Create;
    try
      for i := 0 to Arr.Count - 1 do
        Ids.Add(Arr.Items[i].FindPath('id').AsString);
      Ids.Sort;
      Result := Ids.CommaText;
    finally
      Ids.Free;
    end;
  finally
    J.Free;
  end;
end;

function TDCLLM.ModelAvailable(const ModelName: string): Boolean;
var
  Resp: string;
  J: TJSONData;
  Arr: TJSONArray;
  i: Integer;
  Status: Integer;
begin
  Result := True; // accept if we cannot verify (provider may not expose /models)
  try
    Resp := DoRequest('GET', FConfig.BaseURL + '/models', '', Status);
    if (Status >= 200) and (Status < 300) then
    begin
      J := GetJSON(Resp);
      try
        Arr := J.FindPath('data') as TJSONArray;
        if Arr <> nil then
        begin
          Result := False;
          for i := 0 to Arr.Count - 1 do
            if Arr.Items[i].FindPath('id').AsString = ModelName then
            begin
              Result := True;
              Break;
            end;
        end;
      finally
        J.Free;
      end;
    end;
  except
    Result := True; // network error — don't block the user
  end;
end;

procedure TDCLLM.SetModel(ChatId: UInt64; const ModelName: string);
begin
  if not ModelAvailable(ModelName) then
    raise Exception.CreateFmt('Модель "%s" не в списке доступных (полный список: /model)', [ModelName]);
  EnsureChat(ChatId);
  FModelCache[ChatId] := ModelName;
  SaveMeta(ChatId);
end;

function TDCLLM.ResolveSession(ChatId: UInt64): string;
var
  Body, Resp: string;
  J: TJSONData;
  Status: Integer;
begin
  EnsureChat(ChatId);
  if FSessionCache.IndexOf(ChatId) >= 0 then
    Exit(FSessionCache[ChatId]);
  // no conversation yet — create a new one on the Drift side (new session)
  Body := '{"title":"dcbot chat ' + IntToStr(ChatId) + '"}';
  Resp := DoRequest('POST', FConfig.BaseURL + '/conversations', Body, Status);
  if (Status < 200) or (Status >= 300) then
    raise Exception.CreateFmt('create conversation HTTP %d: %s', [Status, Copy(Resp, 1, 200)]);
  J := GetJSON(Resp);
  try
    Result := SafeStr(J, 'id');
    if Result = 'null' then
      raise Exception.Create('create conversation: no "id" in response');
  finally
    J.Free;
  end;
  FSessionCache[ChatId] := Result;
  SaveMeta(ChatId);
  WriteLn(Format('DEBUG drift session created for chat %d: %s', [ChatId, Result]));
end;

{ Percent-encode a UTF-8 string for use in a URL query. }
function UrlEncode(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    if S[i] in ['a'..'z', 'A'..'Z', '0'..'9', '-', '_', '.', '~'] then
      Result := Result + S[i]
    else
      Result := Result + '%' + IntToHex(Ord(S[i]), 2);
  end;
end;

{ Escape a string for embedding inside a JSON string literal. }
function JsonEscape(const S: string): string;
var
  i: Integer;
begin
  Result := '';
  for i := 1 to Length(S) do
    case S[i] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
      #10: Result := Result + '\n';
      #13: Result := Result + '\r';
      #9:  Result := Result + '\t';
      else Result := Result + S[i];
    end;
end;

{ Copies up to MaxLen bytes of S, never splitting a UTF-8 multi-byte char.
  Returns the whole string if it fits. }
function SafeCopyUtf8(const S: string; MaxLen: Integer): string;
var
  i: Integer;
begin
  if Length(S) <= MaxLen then
    Exit(S);
  i := MaxLen;
  // step back over UTF-8 continuation bytes (0x80..0xBF) to the lead byte
  while (i > 1) and ((Ord(S[i]) and $C0) = $80) do
    Dec(i);
  Result := Copy(S, 1, i - 1);
end;

function TDCLLM.SanitizeUtf8(const S: string): string;
var
  i, k, n, L: Integer;
  b: Byte;
  OK: Boolean;
begin
  Result := '';
  i := 1;
  L := Length(S);
  while i <= L do
  begin
    b := Ord(S[i]);
    if b < $80 then
      n := 1
    else if (b and $E0) = $C0 then n := 2
    else if (b and $F0) = $E0 then n := 3
    else if (b and $F8) = $F0 then n := 4
    else n := 0; // 0x80..0xBF (stray continuation) or 0xF8+ (invalid lead)
    OK := (n > 0) and (i + n - 1 <= L);
    if OK and (n > 1) then
      case n of
        2: if b < $C2 then OK := False; // 0xC0/0xC1 overlong encodings
        3: begin
             if (b = $E0) and (Ord(S[i + 1]) < $A0) then OK := False; // overlong
             if (b = $ED) and (Ord(S[i + 1]) > $9F) then OK := False; // surrogate
           end;
        4: begin
             if (b = $F0) and (Ord(S[i + 1]) < $90) then OK := False; // overlong
             if (b = $F4) and (Ord(S[i + 1]) > $8F) then OK := False; // > U+10FFFF
             if b > $F4 then OK := False; // invalid lead
           end;
      end;
    if OK and (n > 1) then
      for k := 1 to n - 1 do
        if (Ord(S[i + k]) and $C0) <> $80 then
        begin
          OK := False;
          Break;
        end;
    if OK then
    begin
      Result := Result + Copy(S, i, n);
      Inc(i, n);
    end
    else
    begin
      Result := Result + '?';
      Inc(i);
    end;
  end;
end;

function TDCLLM.Search(const Kind, Query: string): string;
const
  Limit = 5;
var
  Url, Body, Resp: string;
  J: TJSONData;
  Arr: TJSONArray;
  Item: TJSONData;
  i: Integer;
  Title, Link, Text: string;
  SL: TStringList;
  Status: Integer;
begin
  Url := FConfig.BaseURL + '/search/';
  if Kind = 'tg' then
  begin
    // GET with query params (cheap Telegram-channel search)
    Url := Url + 'tg?q=' + UrlEncode(Query) + '&limit=' + IntToStr(Limit);
    Body := '';
    Resp := DoRequest('GET', Url, Body, Status);
  end
  else
  begin
    // web / crawl: POST JSON
    Url := Url + Kind;
    if Kind = 'crawl' then
      Body := '{"url":"' + JsonEscape(Query) + '","limit":' + IntToStr(Limit) + '}'
    else
      Body := '{"query":"' + JsonEscape(Query) + '","limit":' + IntToStr(Limit) + '}';
    Resp := DoRequest('POST', Url, Body, Status);
  end;
  if (Status < 200) or (Status >= 300) then
    raise Exception.CreateFmt('Search HTTP %d: %s', [Status, Copy(Resp, 1, 200)]);
  J := GetJSON(Resp);
  try
    Arr := J.FindPath('results') as TJSONArray;
    if Arr = nil then
      Arr := J.FindPath('pages') as TJSONArray; // /search/crawl returns pages
    SL := TStringList.Create;
    try
      if Arr = nil then
        SL.Add('(нет поля results; сырой ответ: ' + Copy(Resp, 1, 300) + ')')
      else if Arr.Count = 0 then
        SL.Add('Ничего не найдено.')
      else
        for i := 0 to Arr.Count - 1 do
        begin
          Item := Arr.Items[i];
          Title := SafeStr(Item, 'title');
          if Title = 'null' then Title := SafeStr(Item, 'channel');
          if Title = 'null' then Title := SafeStr(Item, 'name');
          if Title = 'null' then Title := '';
          Link := SafeStr(Item, 'url');
          if Link = 'null' then Link := SafeStr(Item, 'link');
          if Link = 'null' then Link := SafeStr(Item, 'message_url'); // TG
          if Link = 'null' then Link := '';
          Text := SafeStr(Item, 'text');
          if Text = 'null' then Text := SafeStr(Item, 'snippet');
          if Text = 'null' then Text := SafeStr(Item, 'description');
          if Text = 'null' then Text := SafeStr(Item, 'content'); // web
          if Text = 'null' then Text := '';
          if Link <> '' then
            SL.Add(Format('%d. %s — %s', [i + 1, Title, Link]))
          else
            SL.Add(Format('%d. %s', [i + 1, Title]));
          if Text <> '' then
            SL.Add('   ' + SafeCopyUtf8(Text, 200));
        end;
      Result := SL.Text;
    finally
      SL.Free;
    end;
  finally
    J.Free;
  end;
end;

procedure TDCLLM.ClearContext(ChatId: UInt64);
begin
  if FIsDrift then
  begin
    // New Drift session: the provider keeps per-conversation memory, so we
    // simply forget the old conversation_id — the next request creates a new one.
    EnsureChat(ChatId);
    if FSessionCache.IndexOf(ChatId) >= 0 then
    begin
      FSessionCache.Remove(ChatId);
      SaveMeta(ChatId);
    end;
    WriteLn(Format('DEBUG drift session reset for chat %d', [ChatId]));
  end
  else
  begin
    // Hub: wipe the in-memory history and delete the history file.
    EnsureChat(ChatId);
    FHistory[ChatId].Free;
    FHistory[ChatId] := TJSONArray.Create;
    if FileExists(HistoryPath(ChatId)) then
      DeleteFile(HistoryPath(ChatId));
    WriteLn(Format('DEBUG context cleared for chat %d', [ChatId]));
  end;
end;

initialization
  // Make every string conversion in this process UTF-8. Without this, on
  // C/POSIX locales RawByteString->AnsiString gets tagged CP1252 and fpjson
  // turns non-ASCII response text into '?', corrupting bot replies.
  SetMultiByteConversionCodePage(CP_UTF8);

end.
