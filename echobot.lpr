program EchoBot;

{$mode objfpc}{$H+}

uses
  {$ifdef unix}cthreads,{$endif}
  Classes,
  SysUtils,
  dctransport,
  dcrpcapi,
  dcbot,
  dctypes,
  dcevents,
  dcjson,
  dcllm,
  dcauth,
  dcwatchdog,
  dcqueue,
  fpjson;

var
  Transport: TDCTransport;
  Client: TDCClient;
  Bot: TDCBot;
  LLM: TDCLLM;
  Auth: TAuthStore;
  Watchdog: TDCWatchdog;
  Queue: TTaskQueue;
  AccId: TAccountId;
  SysInfo: TJSONObject;
  AddrOpt: TOptionString;
  WdIntervalSec: Integer;
  WdTimeoutSec: Integer;
  QueueDir: string;
  QueuePollSec: Integer;
  QueueClaimTimeout: Integer;
  ContextMsgs: Integer;

procedure LogEvent(AccId: TAccountId; const Ev: TDCEvent);
begin
  case Ev.Kind of
    ekInfo:    WriteLn('INFO: ' + Ev.Msg);
    ekWarning: WriteLn('WARN: ' + Ev.Msg);
    ekError:   WriteLn('ERROR: ' + Ev.Msg);
  end;
end;

{ Send a text message, sanitizing broken UTF-8 first. deltachat-rpc-server
  dies on invalid UTF-8 ("stream did not contain valid UTF-8"), which used
  to crash the bot when search snippets were cut mid multi-byte char. }
procedure SendMsg(AccId: TAccountId; ChatId: TChatId; const Text: string);
begin
  Client.MiscSendTextMessage(AccId, ChatId, LLM.SanitizeUtf8(Text));
end;

{ Имя файла, безопасное для файловой системы очереди. }
function SanitizeFileName(const S: string): string;
var
  i: Integer;
  c: Char;
begin
  Result := '';
  for i := 1 to Length(S) do
  begin
    c := S[i];
    if (c = '/') or (c = '\') or (c = #0) or (c < ' ') then Continue;
    Result := Result + c;
  end;
  Result := Trim(Result);
  while (Length(Result) > 0) and (Result[1] = '.') do
    Delete(Result, 1, 1);
  if Length(Result) > 120 then
    Result := Copy(Result, 1, 120);
end;

{ Скопировать вложение из сообщения в каталог задачи.
  Возвращает запись с путём относительно корня очереди; RelPath='' — вложения нет.

  Файл может быть ещё не скачан ядром: тогда просим download_full_message и
  ждём, потому что загрузка асинхронная (до ~14 с). }
function FetchAttachment(AccId: TAccountId; var Snap: TMsgSnapshot;
  const TaskId: string): TQueueAttachment;
var
  DestDir, Dest, SrcName: string;
  Src, Dst: TFileStream;
  Tries: Integer;
begin
  Result.RelPath := '';
  Result.Name := '';
  Result.Mime := '';
  if not MsgHasAttachment(Snap) then Exit;

  if Snap.FilePath = '' then
  begin
    try
      Client.DownloadFullMessage(AccId, Snap.Id);
      WriteLn(Format('DEBUG requested full download: msg=%d state=%s bytes=%d',
        [Snap.Id, Snap.DownloadState, Snap.FileBytes]));
    except
      on E: Exception do
        WriteLn(StdErr, 'WARN: download_full_message failed: ' + E.Message);
    end;
    Tries := 0;
    while (Snap.FilePath = '') and (Tries < 20) do
    begin
      Sleep(700);
      Inc(Tries);
      Snap := Client.GetMessage(AccId, Snap.Id);
    end;
  end;

  if Snap.FilePath = '' then
  begin
    WriteLn(StdErr, Format('WARN: attachment of msg %d never became available (viewType=%s state=%s bytes=%d)',
      [Snap.Id, Snap.ViewType, Snap.DownloadState, Snap.FileBytes]));
    Exit;
  end;
  if not FileExists(Snap.FilePath) then
  begin
    WriteLn(StdErr, 'WARN: core points at ' + Snap.FilePath + ' but it does not exist');
    Exit;
  end;

  SrcName := SanitizeFileName(Snap.FileName);
  if SrcName = '' then
    SrcName := SanitizeFileName(ExtractFileName(Snap.FilePath));
  if SrcName = '' then
    SrcName := 'attachment';

  DestDir := IncludeTrailingPathDelimiter(Queue.Root) + 'files' + PathDelim + TaskId + PathDelim;
  if not ForceDirectories(DestDir) then
  begin
    WriteLn(StdErr, 'ERROR: cannot create ' + DestDir);
    Exit;
  end;
  Dest := DestDir + SrcName;
  Src := TFileStream.Create(Snap.FilePath, fmOpenRead or fmShareDenyWrite);
  try
    Dst := TFileStream.Create(Dest, fmCreate);
    try
      Dst.CopyFrom(Src, 0);
    finally
      Dst.Free;
    end;
  finally
    Src.Free;
  end;
  Result.RelPath := 'files/' + TaskId + '/' + SrcName;
  Result.Name := SrcName;
  Result.Mime := Snap.FileMime;
  WriteLn(Format('DEBUG attachment stored: %s (%d bytes) -> %s',
    [Snap.FilePath, Snap.FileBytes, Result.RelPath]));
end;

{ Последние MaxMsgs реплик чата из файла истории — JSON-массив для задачи. }
function BuildContextJSON(ChatId: TChatId; MaxMsgs: Integer): string;
var
  P: string;
  FS: TFileStream;
  J: TJSONData;
  Arr, Tail: TJSONArray;
  i, From_: Integer;
begin
  Result := '';
  P := IncludeTrailingPathDelimiter(LLM.HistoryDir) + IntToStr(ChatId) + '.json';
  if not FileExists(P) then Exit;
  J := nil;
  try
    try
      FS := TFileStream.Create(P, fmOpenRead or fmShareDenyWrite);
      try
        J := GetJSON(FS);
      finally
        FS.Free;
      end;
      if not (J is TJSONArray) then Exit;
      Arr := J as TJSONArray;
      Tail := TJSONArray.Create;
      try
        From_ := Arr.Count - MaxMsgs;
        if From_ < 0 then From_ := 0;
        for i := From_ to Arr.Count - 1 do
          Tail.Add(Arr.Items[i].Clone);
        Result := Tail.AsJSON;
      finally
        Tail.Free;
      end;
    except
      on E: Exception do
        WriteLn(StdErr, 'WARN: cannot read chat history for context: ' + E.Message);
    end;
  finally
    if Assigned(J) then J.Free;
  end;
end;

{ Поставить задачу в очередь и подтвердить приём в чате. }
procedure EnqueueTask(const Snap: TMsgSnapshot; const Worker, TaskText: string);
var
  Att: TQueueAttachments;
  S: TMsgSnapshot;
  Id, Ctx, Ack: string;
begin
  S := Snap;
  Id := QueueNewId;
  SetLength(Att, 0);
  if MsgHasAttachment(S) then
  begin
    SetLength(Att, 1);
    Att[0] := FetchAttachment(AccId, S, Id);
    if Att[0].RelPath = '' then
      SetLength(Att, 0);
  end;
  Ctx := BuildContextJSON(S.ChatId, ContextMsgs);
  try
    Id := Queue.Enqueue(Id, S.ChatId, Worker, TaskText, Ctx, Att);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'ERROR: cannot enqueue task: ' + E.Message);
      SendMsg(AccId, S.ChatId, '❌ Не удалось поставить задачу: ' + E.Message);
      Exit;
    end;
  end;
  Ack := '📥 Задача ' + Id + ' принята';
  if Worker <> 'any' then
    Ack := Ack + ' (воркер: ' + Worker + ')';
  if Length(Att) > 0 then
    Ack := Ack + ', вложений: ' + IntToStr(Length(Att));
  SendMsg(AccId, S.ChatId, Ack);
  WriteLn(Format('DEBUG task enqueued: %s chat=%d worker=%s att=%d text=%d chars',
    [Id, S.ChatId, Worker, Length(Att), Length(TaskText)]));
end;

{ Доставка результата задачи: короткий текст + файлы-вложения.
  Вызывается из потока очереди; RPC потокобезопасен (critical section). }
procedure DeliverResult(const Res: TTaskResult);
var
  i: Integer;
  Abs, Text: string;
begin
  Text := Res.Text;
  if Length(Text) > 3500 then
    Text := Copy(Text, 1, 3500) + LineEnding + '(сокращено — полностью в файле)';
  if not Res.Ok then
    Text := '⚠️ Задача ' + Res.Id + ' не выполнена' + LineEnding + Text;
  if Trim(Text) = '' then
    Text := '✅ Задача ' + Res.Id + ' выполнена (воркер ' + Res.Worker + ')';
  SendMsg(AccId, Res.ChatId, Text);
  for i := 0 to High(Res.Attachments) do
  begin
    Abs := IncludeTrailingPathDelimiter(Queue.Root) + Res.Attachments[i].RelPath;
    if not FileExists(Abs) then
    begin
      WriteLn(StdErr, 'WARN: result attachment missing: ' + Abs);
      Continue;
    end;
    try
      Client.MiscSendMsg(AccId, Res.ChatId, '', Abs, Res.Attachments[i].Name, 0);
      WriteLn(Format('DEBUG sent attachment %s to chat %d', [Abs, Res.ChatId]));
    except
      on E: Exception do
        WriteLn(StdErr, 'ERROR: cannot send attachment ' + Abs + ': ' + E.Message);
    end;
  end;
end;

procedure HandleNewMsg(AccId: TAccountId; MsgId: TMsgId);
var
  Snap: TMsgSnapshot;
  Text, Reply, Code: string;
  M, Q, Kind, W: string;
  P: Integer;
  CId: TChatId;
begin
  Snap := Client.GetMessage(AccId, MsgId);
  WriteLn(Format('DEBUG msg id=%d chat=%d from=%d isBot=%s isInfo=%s view=%s state=%s bytes=%d file="%s" text="%s"',
    [Snap.Id, Snap.ChatId, Snap.FromId,
     BoolToStr(Snap.IsBot, True), BoolToStr(Snap.IsInfo, True),
     Snap.ViewType, Snap.DownloadState, Snap.FileBytes, Snap.FilePath, Snap.Text]));
  if Snap.FromId <= ContactLastSpecial then Exit;
  Text := Trim(Snap.Text);
  if (Text = '') and not MsgHasAttachment(Snap) then Exit;

  // --- authorization gate ---
  if Auth.Enabled and not Auth.IsAuthorized(Snap.FromId) then
  begin
    if Copy(Text, 1, 7) = '/start ' then
    begin
      Code := Trim(Copy(Text, 8, Length(Text) - 7));
      if Code = Auth.Code then
      begin
        Auth.Authorize(Snap.FromId);
        WriteLn(Format('DEBUG authorized contact %d', [Snap.FromId]));
        SendMsg(AccId, Snap.ChatId, '✅ Авторизация пройдена. Добро пожаловать!');
      end
      else
        SendMsg(AccId, Snap.ChatId, '🔒 Неверный код. Доступ запрещён.');
    end
    else if Text = '/start' then
      SendMsg(AccId, Snap.ChatId, '🔒 Отправь /start <кодовая фраза> для авторизации')
    else
      WriteLn(Format('DEBUG ignoring message from unauthorized contact %d', [Snap.FromId]));
    Exit;
  end;

  if Text = '/start' then
  begin
    WriteLn('DEBUG replying with "работаю" to /start');
    SendMsg(AccId, Snap.ChatId, 'работаю');
    Exit;
  end;

  // --- SecureJoin: приём приглашения Delta Chat (verified-контакт + E2EE) ---
  if (Copy(Text, 1, 6) = '/join ') or (Pos('i.delta.chat/#', Text) > 0)
    or (Pos('OPENPGP4FPR:', Text) > 0) then
  begin
    Q := Text;
    if Copy(Text, 1, 6) = '/join ' then
      Q := Trim(Copy(Text, 7, Length(Text) - 6));
    P := Pos('https://i.delta.chat/#', Q);
    if P = 0 then
      P := Pos('OPENPGP4FPR:', Q);
    if P = 0 then
      Reply := 'Не вижу ссылку-приглашение. Формат: /join https://i.delta.chat/#…'
    else
    begin
      Q := Trim(Copy(Q, P, Length(Q) - P + 1));
      P := Pos(' ', Q);
      if P > 0 then
        Q := Copy(Q, 1, P - 1);
      WriteLn(Format('DEBUG secure_join: приглашение длиной %d символов, чат=%d',
        [Length(Q), Snap.ChatId]));
      Flush(Output);
      try
        CId := Client.SecureJoin(AccId, Q);
        Reply := Format('🔐 Приглашение принято (чат %d). Рукопожатие идёт в фоне: ' +
          'через несколько секунд контакт станет проверенным, и переписка пойдёт ' +
          'зашифрованной — в чате появится признак шифрования.', [CId]);
      except
        on E: Exception do
          Reply := '❌ SecureJoin не сработал: ' + E.Message;
      end;
    end;
    SendMsg(AccId, Snap.ChatId, Reply);
    Exit;
  end;

  // --- bot commands ---
  if Text = '/help' then
  begin
    SendMsg(AccId, Snap.ChatId,
      'Команды:' + LineEnding +
      '/agent [pc|laptop] <задача> — задача агенту (можно приложить файл/фото)' + LineEnding +
      '/status — состояние очереди задач' + LineEnding +
      '/model — текущая модель и список доступных' + LineEnding +
      '/model <имя> — сменить модель для этого чата' + LineEnding +
      '/search <запрос> — поиск в интернете' + LineEnding +
      '/search tg <запрос> — поиск по Telegram-каналам' + LineEnding +
      '/search crawl <url> — обойти сайт' + LineEnding +
      '/join <ссылка-приглашение> — принять SecureJoin (шифрованный контакт)' + LineEnding +
      '/clear — очистить контекст чата' + LineEnding +
      '  (для Drift — создать новую сессию)' + LineEnding +
      LineEnding +
      'Всё остальное — простой запрос: отвечает модель, без инструментов.' + LineEnding +
      'Фото и файлы уходят агенту автоматически.');
    Exit;
  end;

  // --- задачи агенту ---
  if (Text = '/agent') or (Copy(Text, 1, 7) = '/agent ') then
  begin
    W := 'any';
    Q := Trim(Copy(Text, 8, Length(Text) - 7));
    P := Pos(' ', Q);
    if P > 0 then
    begin
      M := LowerCase(Copy(Q, 1, P - 1));
      if (M = 'pc') or (M = 'laptop') then
      begin
        W := M;
        Q := Trim(Copy(Q, P + 1, Length(Q) - P));
      end;
    end;
    if (Q = '') and not MsgHasAttachment(Snap) then
      SendMsg(AccId, Snap.ChatId,
        'Использование: /agent [pc|laptop] <задача>' + LineEnding +
        'Можно приложить файл или фото — уйдёт агенту вместе с задачей.')
    else
      EnqueueTask(Snap, W, Q);
    Exit;
  end;

  if Text = '/status' then
  begin
    SendMsg(AccId, Snap.ChatId, Queue.StatusText);
    Exit;
  end;

  if not LLM.IsConfigured then
  begin
    WriteLn('WARN: LLM not configured (set LLM_API_KEY), ignoring message');
    Exit;
  end;

  if (Text = '/model') or (Copy(Text, 1, 7) = '/model ') then
  begin
    M := Trim(Copy(Text, 8, Length(Text) - 7));
    if M = '' then
    begin
      try
        Reply := 'Модель чата: ' + LLM.ChatModel(Snap.ChatId) + LineEnding +
                 LLM.FormatModelsForChat(Snap.ChatId);
      except
        on E: Exception do
          Reply := 'Ошибка: ' + E.Message;
      end;
    end
    else
    begin
      try
        LLM.SetModel(Snap.ChatId, M);
        Reply := '✅ Модель чата: ' + M;
      except
        on E: Exception do
          Reply := '❌ ' + E.Message;
      end;
    end;
    SendMsg(AccId, Snap.ChatId, Reply);
    Exit;
  end;

  if Text = '/clear' then
  begin
    try
      LLM.ClearContext(Snap.ChatId);
      if LLM.IsDrift then
        Reply := '🧹 Создана новая сессия Drift.'
      else
        Reply := '🧹 Контекст чата очищен.';
    except
      on E: Exception do
        Reply := '❌ ' + E.Message;
    end;
    SendMsg(AccId, Snap.ChatId, Reply);
    Exit;
  end;

  if Copy(Text, 1, 8) = '/search ' then
  begin
    Q := Trim(Copy(Text, 9, Length(Text) - 8));
    Kind := 'web';
    P := Pos(' ', Q);
    if P > 0 then
    begin
      W := LowerCase(Copy(Q, 1, P - 1));
      if (W = 'web') or (W = 'tg') or (W = 'crawl') then
      begin
        Kind := W;
        Q := Trim(Copy(Q, P + 1, Length(Q) - P));
      end;
    end;
    if Q = '' then
      Reply := 'Использование: /search <запрос> | /search tg <запрос> | /search crawl <url>'
    else
    begin
      WriteLn(Format('DEBUG search kind=%s q="%s" chat=%d', [Kind, Q, Snap.ChatId]));
      Flush(Output);
      try
        Reply := '🔎 ' + Kind + ': ' + Q + LineEnding + LLM.Search(Kind, Q);
      except
        on E: Exception do
          Reply := '❌ Ошибка поиска: ' + E.Message;
      end;
    end;
    SendMsg(AccId, Snap.ChatId, Reply);
    Exit;
  end;

  // Вложения простая модель не увидит — их обрабатывает только агент.
  if MsgHasAttachment(Snap) then
  begin
    EnqueueTask(Snap, 'any', Text);
    Exit;
  end;

  WriteLn(Format('DEBUG LLM -> chat=%d (%d chars)', [Snap.ChatId, Length(Text)]));
  Flush(Output);
  WatchdogBusy := True;
  try
    try
      Reply := LLM.Complete(Snap.ChatId, Text);
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'ERROR: LLM call failed: ' + E.Message);
        Reply := '';
      end;
    end;
  finally
    WatchdogBusy := False;
  end;
  if Reply <> '' then
  begin
    WriteLn(Format('DEBUG LLM <- chat=%d (%d chars)', [Snap.ChatId, Length(Reply)]));
    SendMsg(AccId, Snap.ChatId, Reply);
  end;
end;

begin
  Transport := TDCTransport.Create;
  Transport.Open;
  Client := TDCClient.Create(Transport);
  Bot := TDCBot.Create(Client);
  LLM := TDCLLM.Create;
  Auth := TAuthStore.Create;

  AccId := GetAccount(Client);

  SysInfo := Client.GetSystemInfo;
  WriteLn('Running deltachat core ' + SysInfo.Find('deltachat_core_version').AsString);
  SysInfo.Free;

  if LLM.IsConfigured then
    WriteLn('LLM: ' + LLM.Model + ' @ ' + LLM.BaseURL + ' (history: ' + LLM.HistoryDir + ')')
  else
    WriteLn('LLM: not configured (set LLM_API_KEY) — bot replies only to /start');

  if Auth.Enabled then
    WriteLn(Format('Auth: enabled (%d authorized contacts, file %s)', [Auth.Count, Auth.Path]))
  else
    WriteLn('Auth: disabled (set BOT_AUTH_CODE) — bot is open');

  // Task queue for the agents (see dcqueue.pas). Started before Bot.Run so that
  // results produced while the bot was down are delivered right away.
  QueueDir := GetEnvironmentVariable('QUEUE_DIR');
  if QueueDir = '' then QueueDir := 'queue';
  QueuePollSec := StrToIntDef(GetEnvironmentVariable('QUEUE_POLL_INTERVAL'), 5);
  QueueClaimTimeout := StrToIntDef(GetEnvironmentVariable('QUEUE_CLAIM_TIMEOUT'), 1800);
  ContextMsgs := StrToIntDef(GetEnvironmentVariable('QUEUE_CONTEXT_MSGS'), 3);
  Queue := TTaskQueue.Create(QueueDir, GetEnvironmentVariable('QUEUE_WORKER_NAME'),
    QueuePollSec * 1000, QueueClaimTimeout, @DeliverResult);
  WriteLn(Format('Queue: %s (poll %d s, claim timeout %d s, context %d msgs)',
    [Queue.Root, QueuePollSec, QueueClaimTimeout, ContextMsgs]));

  // Watchdog: pings the core; on timeout it Halt(1)s so systemd restarts us.
  if GetEnvironmentVariable('BOT_WATCHDOG') <> '0' then
  begin
    WdIntervalSec := StrToIntDef(GetEnvironmentVariable('BOT_WATCHDOG_INTERVAL'), 30);
    WdTimeoutSec := StrToIntDef(GetEnvironmentVariable('BOT_WATCHDOG_TIMEOUT'), 15);
    Watchdog := TDCWatchdog.Create(Client.Rpc, AccId, WdIntervalSec, WdTimeoutSec);
    WriteLn(Format('Watchdog: enabled (every %d s, timeout %d s)', [WdIntervalSec, WdTimeoutSec]));
  end
  else
  begin
    Watchdog := nil;
    WriteLn('Watchdog: disabled (BOT_WATCHDOG=0)');
  end;
  Flush(Output); // ensure the banner reaches the journal even on restart

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
  Queue.Terminate;
  Queue.WaitFor;
  Queue.Free;
  if Assigned(Watchdog) then
  begin
    Watchdog.Terminate;
    Watchdog.WaitFor;
    Watchdog.Free;
  end;
  Auth.Free;
  LLM.Free;
  Client.Free;
  Transport.Close;
  Transport.Free;
end.
