unit dcwatchdog;

{ Watchdog for the deltachat-rpc-server core.
  The core (deltachat-core-rust v2.57.0) occasionally deadlocks while
  processing incoming mail: the process stays alive, but it stops
  responding to RPC and never emits events, so the bot hangs forever.
  Restart reliably recovers (pending messages are re-processed on boot).

  This thread pings the core with a lightweight RPC (get_system_info)
  every BOT_WATCHDOG_INTERVAL seconds and waits up to
  BOT_WATCHDOG_TIMEOUT seconds for a reply. On timeout it logs and calls
  Halt(1), letting systemd's Restart=always bring the bot back.

  Disable with BOT_WATCHDOG=0.
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpjson, dcrpc;

type
  TDCWatchdog = class(TThread)
  private
    FRpc: TRpc;
    FIntervalMs: Integer;
    FTimeoutMs: Integer;
  protected
    procedure Execute; override;
  public
    constructor Create(ARpc: TRpc; IntervalSec, TimeoutSec: Integer);
  end;

implementation

constructor TDCWatchdog.Create(ARpc: TRpc; IntervalSec, TimeoutSec: Integer);
begin
  inherited Create(True); // create suspended
  FRpc := ARpc;
  FIntervalMs := IntervalSec * 1000;
  FTimeoutMs := TimeoutSec * 1000;
  FreeOnTerminate := False;
  Start;
end;

procedure TDCWatchdog.Execute;
var
  Res: TJSONData;
begin
  while not Terminated do
  begin
    Sleep(FIntervalMs);
    if Terminated then Break;
    try
      Res := FRpc.CallResultTimeout('get_system_info', TJSONArray.Create, FTimeoutMs);
      Res.Free;
    except
      on E: Exception do
      begin
        WriteLn(StdErr, 'WATCHDOG: core not responding (' + E.Message + '), restarting');
        Flush(StdErr);
        Halt(1);
      end;
    end;
  end;
end;

end.
