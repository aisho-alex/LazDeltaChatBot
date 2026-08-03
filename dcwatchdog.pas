unit dcwatchdog;

{ Watchdog for the deltachat-rpc-server core.

  The core (deltachat-core-rust v2.57.0) has a partial-deadlock failure
  mode: while processing an incoming message it freezes internally —
  get_system_info (and other simple RPCs) keep answering, but the event
  channel stops delivering events, so the bot waits in get_next_event
  forever and the message never gets processed.

  This thread polls get_next_msgs every BOT_WATCHDOG_INTERVAL seconds
  (default 30) with a BOT_WATCHDOG_TIMEOUT second limit (default 15):

  - RPC timeout / error        -> core is fully dead   -> Halt(1)
  - a message id is pending on TWO consecutive polls while the bot is
    NOT busy inside an LLM call (WatchdogBusy=false) -> events are stuck
    -> Halt(1)

  Halt(1) lets systemd's Restart=always bring the bot back; pending
  messages are re-processed on boot via get_next_msgs.

  Disable with BOT_WATCHDOG=0.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, dcrpc, dctypes;

var
  { Set by the bot around long LLM calls so the watchdog does not treat a
    message that is pending while the bot is busy as a stuck event flow. }
  WatchdogBusy: Boolean = False;

type
  TDCWatchdog = class(TThread)
  private
    FRpc: TRpc;
    FAccId: TAccountId;
    FIntervalMs: Integer;
    FTimeoutMs: Integer;
    FPrevPending: array of TMsgId;
    procedure CheckPending(const Ids: array of TMsgId);
    procedure Die(const Reason: string);
  protected
    procedure Execute; override;
  public
    constructor Create(ARpc: TRpc; AAccId: TAccountId; IntervalSec, TimeoutSec: Integer);
  end;

implementation

constructor TDCWatchdog.Create(ARpc: TRpc; AAccId: TAccountId; IntervalSec, TimeoutSec: Integer);
begin
  inherited Create(True); // create suspended
  FRpc := ARpc;
  FAccId := AAccId;
  FIntervalMs := IntervalSec * 1000;
  FTimeoutMs := TimeoutSec * 1000;
  FreeOnTerminate := False;
  Start;
end;

procedure TDCWatchdog.Die(const Reason: string);
begin
  WriteLn(StdErr, 'WATCHDOG: ' + Reason + ', restarting');
  Flush(StdErr);
  Halt(1);
end;

procedure TDCWatchdog.CheckPending(const Ids: array of TMsgId);
var
  i, j: Integer;
  Found: Boolean;
begin
  if WatchdogBusy then Exit; // bot is inside an LLM call — pending is expected
  // restart if any id is pending on two consecutive polls
  for i := Low(Ids) to High(Ids) do
  begin
    Found := False;
    for j := Low(FPrevPending) to High(FPrevPending) do
      if FPrevPending[j] = Ids[i] then
      begin
        Found := True;
        Break;
      end;
    if Found then
      Die(Format('message %d stuck unprocessed for two polls (event flow broken?)', [Ids[i]]));
  end;
end;

procedure TDCWatchdog.Execute;
var
  Params: TJSONArray;
  Res: TJSONData;
  Arr: TJSONArray;
  Ids: array of TMsgId;
  i: Integer;
begin
  while not Terminated do
  begin
    Sleep(FIntervalMs);
    if Terminated then Break;
    SetLength(Ids, 0);
    try
      Params := TJSONArray.Create;
      Params.Add(FAccId);
      Res := FRpc.CallResultTimeout('get_next_msgs', Params, FTimeoutMs);
      try
        if Res is TJSONArray then
        begin
          Arr := Res as TJSONArray;
          SetLength(Ids, Arr.Count);
          for i := 0 to Arr.Count - 1 do
            Ids[i] := Arr.Items[i].AsQWord;
        end;
      finally
        Res.Free;
      end;
    except
      on E: Exception do
        Die('core not responding (' + E.Message + ')');
    end;
    CheckPending(Ids);
    FPrevPending := Ids; // empty array clears the previous state
  end;
end;

end.
