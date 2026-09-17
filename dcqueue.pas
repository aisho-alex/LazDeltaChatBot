unit dcqueue;

{ File-based task queue between the Delta Chat bot and Hermes workers.

  Layout (QUEUE_DIR, default <cwd>/queue):

    inbox/<id>.json             задача ждёт воркера
    claimed/<id>.json.<worker>  воркер забрал (захват через `mv` — атомарный)
    outbox/<id>.json            результат готов, бот его доставляет
    done/                       архив обработанных (и failed-*)
    files/<id>/                 вложения к задаче и файлы результата

  Разделение обязанностей:
    - бот только кладёт задачи в inbox/ и разбирает outbox/;
    - воркер (отдельный процесс, возможно на другой машине, опрашивает очередь
      по ssh) забирает задачу одним `mv`, обновляет свой claim как heartbeat и
      пишет результат в outbox/.
  Захват атомарен на уровне POSIX rename, поэтому два воркера физически не могут
  взять одну задачу. Если воркер умер (ребут), его claim «остывает» и бот
  возвращает задачу в inbox через QUEUE_CLAIM_TIMEOUT секунд.

  Формат задачи (inbox/<id>.json) как плоский список полей:
    id          строка вида 20260917-061500-a7f3
    chat_id     чат Delta Chat, куда вернуть результат
    worker      any | laptop | pc — кто имеет право взять задачу
    created     unix-время постановки
    task        текст задачи (может быть пустым, если есть вложение)
    context     массив последних реплик чата: role / content
    attachments массив: path (относительно корня очереди) / name / mime

  Формат результата (outbox/<id>.json): id, chat_id, ok, worker, text
  (короткий ответ для чата) и attachments — те же поля, что у задачи.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, DateUtils, fpjson, dctypes;

type
  TQueueAttachment = record
    RelPath: string;   // относительно корня очереди: files/<id>/name
    Name: string;
    Mime: string;
  end;
  TQueueAttachments = array of TQueueAttachment;

  TTaskResult = record
    Id: string;
    ChatId: TChatId;
    Ok: Boolean;
    Worker: string;
    Text: string;
    Attachments: TQueueAttachments;
  end;

  { Вызывается из потока очереди, когда результат готов к отправке в чат.
    Реализация (echobot.lpr) шлёт текст и вложения через RPC. }
  TTaskDeliverProc = procedure(const Res: TTaskResult);

  TTaskQueue = class(TThread)
  private
    FRoot: string;
    FLocalWorker: string;
    FPollMs: Integer;
    FClaimTimeoutSec: Integer;
    FDeliver: TTaskDeliverProc;
    FAttempts: TStringList;   // "<id>=<попыток доставки>"
    function SubDir(const Name: string): string;
    procedure ReclaimStale;
    procedure ScanOutbox;
    procedure DeliverFile(const FilePath: string);
  protected
    procedure Execute; override;
  public
    constructor Create(const ARoot, ALocalWorker: string; APollMs, AClaimTimeoutSec: Integer;
      ADeliver: TTaskDeliverProc);
    destructor Destroy; override;
    procedure EnsureDirs;
    function Enqueue(const Id: string; ChatId: TChatId; const Worker, TaskText, ContextJSON: string;
      const Att: TQueueAttachments): string;
    function StatusText: string;
    property Root: string read FRoot;
  end;

function QueueNewId: string;
function UnixNow: Int64;

implementation

const
  MaxDeliverAttempts = 10;

function UnixNow: Int64;
begin
  Result := DateTimeToUnix(Now);
end;

{ mtime файла как Unix-время; 0 если файла нет. }
function FileMTime(const P: string): Int64;
var
  H: THandle;
begin
  Result := 0;
  H := FileOpen(P, fmOpenRead or fmShareDenyNone);
  if H = feInvalidHandle then Exit;
  try
    Result := FileGetDate(H);
  finally
    FileClose(H);
  end;
end;

function JsonField(O: TJSONObject; const Key: string): string;
var
  D: TJSONData;
begin
  Result := '';
  if not Assigned(O) then Exit;
  D := O.Find(Key);
  if Assigned(D) and not (D is TJSONNull) then
    Result := D.AsString;
end;

function QueueNewId: string;
begin
  Result := FormatDateTime('yyyymmdd-hhnnss', Now) + '-' + IntToHex(Random($10000), 4);
end;

constructor TTaskQueue.Create(const ARoot, ALocalWorker: string;
  APollMs, AClaimTimeoutSec: Integer; ADeliver: TTaskDeliverProc);
begin
  inherited Create(True); // suspended: fields must be set before Execute runs
  FRoot := ARoot;
  FLocalWorker := ALocalWorker;
  FPollMs := APollMs;
  if FPollMs < 1000 then FPollMs := 1000;
  FClaimTimeoutSec := AClaimTimeoutSec;
  FDeliver := ADeliver;
  FAttempts := TStringList.Create;
  FAttempts.NameValueSeparator := '=';
  FreeOnTerminate := False;
  Randomize;
  EnsureDirs;
  Start;
end;

destructor TTaskQueue.Destroy;
begin
  FAttempts.Free;
  inherited Destroy;
end;

function TTaskQueue.SubDir(const Name: string): string;
begin
  Result := IncludeTrailingPathDelimiter(FRoot) + Name + PathDelim;
end;

procedure TTaskQueue.EnsureDirs;
const
  SubDirs: array[0..4] of string = ('inbox', 'claimed', 'outbox', 'done', 'files');
var
  i: Integer;
begin
  for i := Low(SubDirs) to High(SubDirs) do
    if not ForceDirectories(SubDir(SubDirs[i])) then
      WriteLn(StdErr, 'ERROR: cannot create queue dir ' + SubDir(SubDirs[i]));
end;

function TTaskQueue.Enqueue(const Id: string; ChatId: TChatId;
  const Worker, TaskText, ContextJSON: string; const Att: TQueueAttachments): string;
var
  S, TmpPath, FinalPath: string;
  Obj: TJSONObject;
  Arr, Ctx: TJSONArray;
  AObj: TJSONObject;
  J: TJSONData;
  FS: TFileStream;
  i: Integer;
begin
  EnsureDirs;
  Obj := TJSONObject.Create;
  try
    Obj.Add('id', Id);
    Obj.Add('chat_id', Int64(ChatId));
    Obj.Add('worker', Worker);
    Obj.Add('created', UnixNow);
    Obj.Add('task', TaskText);
    Ctx := TJSONArray.Create;
    if Trim(ContextJSON) <> '' then
    begin
      J := nil;
      try
        J := GetJSON(ContextJSON);
        if J is TJSONArray then
        begin
          Ctx.Free;
          Ctx := (J as TJSONArray).Clone as TJSONArray;
        end;
      except
        on E: Exception do
          WriteLn(StdErr, 'WARN: cannot parse context JSON: ' + E.Message);
      end;
      if Assigned(J) then J.Free;
    end;
    Obj.Add('context', Ctx);
    Arr := TJSONArray.Create;
    for i := 0 to High(Att) do
    begin
      AObj := TJSONObject.Create;
      AObj.Add('path', Att[i].RelPath);
      AObj.Add('name', Att[i].Name);
      AObj.Add('mime', Att[i].Mime);
      Arr.Add(AObj);
    end;
    Obj.Add('attachments', Arr);
    S := Obj.AsJSON;
  finally
    Obj.Free;
  end;
  FinalPath := SubDir('inbox') + Id + '.json';
  TmpPath := FinalPath + '.tmp';
  FS := TFileStream.Create(TmpPath, fmCreate);
  try
    FS.WriteBuffer(S[1], Length(S));
  finally
    FS.Free;
  end;
  if not RenameFile(TmpPath, FinalPath) then
    raise Exception.Create('cannot publish task ' + Id);
  Result := Id;
end;

procedure TTaskQueue.ReclaimStale;
var
  SR: TSearchRec;
  Dir, Id, Worker, Name: string;
  Age: Int64;
  p: Integer;
begin
  Dir := SubDir('claimed');
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(Dir + '*', faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) <> 0 then Continue;
      Name := SR.Name;
      Id := Name;
      Worker := '';
      p := Pos('.json.', Name);
      if p > 0 then
      begin
        Id := Copy(Name, 1, p - 1);
        Worker := Copy(Name, p + 6, MaxInt);
      end;
      Age := UnixNow - FileMTime(Dir + Name);
      if Age > FClaimTimeoutSec then
      begin
        if RenameFile(Dir + Name, SubDir('inbox') + Id + '.json') then
          WriteLn(Format('WARN: task %s reclaimed from worker %s (no heartbeat for %d s)',
            [Id, Worker, Age]))
        else
          WriteLn(StdErr, Format('WARN: cannot reclaim task %s', [Id]));
      end;
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure TTaskQueue.ScanOutbox;
var
  SR: TSearchRec;
  Dir: string;
begin
  Dir := SubDir('outbox');
  if not DirectoryExists(Dir) then Exit;
  if FindFirst(Dir + '*.json', faAnyFile, SR) <> 0 then Exit;
  try
    repeat
      if (SR.Attr and faDirectory) = 0 then
        DeliverFile(Dir + SR.Name);
    until FindNext(SR) <> 0;
  finally
    FindClose(SR);
  end;
end;

procedure TTaskQueue.DeliverFile(const FilePath: string);
var
  FS: TFileStream;
  J: TJSONData;
  Obj: TJSONObject;
  Arr: TJSONArray;
  D: TJSONData;
  Res: TTaskResult;
  i, Attempts: Integer;
begin
  J := nil;
  try
    try
      FS := TFileStream.Create(FilePath, fmOpenRead or fmShareDenyWrite);
      try
        J := GetJSON(FS);
      finally
        FS.Free;
      end;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'WARN: unreadable result ' + FilePath + ': ' + E.Message);
        RenameFile(FilePath, SubDir('done') + 'broken-' + ExtractFileName(FilePath));
        Exit;
      end;
    end;

    Obj := J as TJSONObject;
    Res := Default(TTaskResult);
    Res.Id := JsonField(Obj, 'id');
    if Res.Id = '' then
      Res.Id := ChangeFileExt(ExtractFileName(FilePath), '');
    D := Obj.Find('chat_id');
    if Assigned(D) and not (D is TJSONNull) then Res.ChatId := D.AsQWord;
    D := Obj.Find('ok');
    if Assigned(D) then Res.Ok := D.AsBoolean else Res.Ok := True;
    Res.Worker := JsonField(Obj, 'worker');
    Res.Text := JsonField(Obj, 'text');
    D := Obj.Find('attachments');
    if Assigned(D) and (D is TJSONArray) then
    begin
      Arr := D as TJSONArray;
      SetLength(Res.Attachments, Arr.Count);
      for i := 0 to Arr.Count - 1 do
      begin
        Res.Attachments[i].RelPath := JsonField(Arr.Objects[i], 'path');
        Res.Attachments[i].Name := JsonField(Arr.Objects[i], 'name');
        Res.Attachments[i].Mime := JsonField(Arr.Objects[i], 'mime');
      end;
    end;

    if Res.ChatId = 0 then
    begin
      WriteLn(StdErr, 'WARN: result ' + FilePath + ' has no chat_id, archiving');
      RenameFile(FilePath, SubDir('done') + ExtractFileName(FilePath));
      Exit;
    end;

    try
      if Assigned(FDeliver) then
        FDeliver(Res);
      if not RenameFile(FilePath, SubDir('done') + ExtractFileName(FilePath)) then
        DeleteFile(FilePath);
      FAttempts.Clear;
      WriteLn(Format('DEBUG queue: delivered result %s (worker %s)', [Res.Id, Res.Worker]));
    except
      on E: Exception do
      begin
        Attempts := 1;
        i := FAttempts.IndexOfName(Res.Id);
        if i >= 0 then
          Attempts := StrToIntDef(FAttempts.ValueFromIndex[i], 0) + 1;
        if i < 0 then
          FAttempts.Add(Res.Id + '=' + IntToStr(Attempts))
        else
          FAttempts[i] := Res.Id + '=' + IntToStr(Attempts);
        WriteLn(StdErr, Format('WARN: delivery of %s failed (%d/%d): %s',
          [Res.Id, Attempts, MaxDeliverAttempts, E.Message]));
        if Attempts >= MaxDeliverAttempts then
          RenameFile(FilePath, SubDir('done') + 'failed-' + ExtractFileName(FilePath));
      end;
    end;
  finally
    if Assigned(J) then J.Free;
  end;
end;

procedure TTaskQueue.Execute;
begin
  while not Terminated do
  begin
    Sleep(FPollMs);
    if Terminated then Break;
    try
      ReclaimStale;
      ScanOutbox;
    except
      on E: Exception do
        WriteLn(StdErr, 'WARN: queue tick failed: ' + E.Message);
    end;
  end;
end;

function TTaskQueue.StatusText: string;
var
  Lines: TStringList;
  SR: TSearchRec;
  p: Integer;
  Id, Worker, Name: string;
  Age: Int64;

  function CountOf(const Dir, Mask: string): Integer;
  var
    R: TSearchRec;
  begin
    Result := 0;
    if FindFirst(Dir + Mask, faAnyFile, R) <> 0 then Exit;
    try
      repeat
        if (R.Attr and faDirectory) = 0 then Inc(Result);
      until FindNext(R) <> 0;
    finally
      FindClose(R);
    end;
  end;

begin
  Lines := TStringList.Create;
  try
    Lines.Add(Format('Очередь задач (воркер канала: %s)', [FLocalWorker]));
    Lines.Add(Format('ждёт: %d · в работе: %d · результатов: %d · архив: %d',
      [CountOf(SubDir('inbox'), '*.json'), CountOf(SubDir('claimed'), '*'),
       CountOf(SubDir('outbox'), '*.json'), CountOf(SubDir('done'), '*')]));
    if FindFirst(SubDir('claimed') + '*', faAnyFile, SR) = 0 then
    begin
      try
        repeat
          if (SR.Attr and faDirectory) <> 0 then Continue;
          Name := SR.Name;
          Id := Name;
          Worker := '?';
          p := Pos('.json.', Name);
          if p > 0 then
          begin
            Id := Copy(Name, 1, p - 1);
            Worker := Copy(Name, p + 6, MaxInt);
          end;
          Age := (UnixNow - FileMTime(SubDir('claimed') + Name)) div 60;
          Lines.Add(Format('  в работе: %s — воркер %s, тишина %d мин', [Id, Worker, Age]));
        until FindNext(SR) <> 0;
      finally
        FindClose(SR);
      end;
    end;
    if CountOf(SubDir('inbox'), '*.json') > 0 then
    begin
      if FindFirst(SubDir('inbox') + '*.json', faAnyFile, SR) = 0 then
      begin
        try
          repeat
            Lines.Add('  ждёт: ' + ChangeFileExt(SR.Name, ''));
          until FindNext(SR) <> 0;
        finally
          FindClose(SR);
        end;
      end;
    end;
    Result := Lines.Text;
  finally
    Lines.Free;
  end;
end;

end.
