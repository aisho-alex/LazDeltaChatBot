unit dcrpc;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, syncobjs, fpjson, jsonparser, dctransport, fgl;

type
  TResponseMap = specialize TFPGMap<UInt64, TJSONData>;
  TEventMap    = specialize TFPGMap<UInt64, TEvent>;

  TRpc = class;

  TRpcReaderThread = class(TThread)
  private
    FRpc: TRpc;
  protected
    procedure Execute; override;
  public
    constructor Create(ARpc: TRpc);
  end;

  TRpc = class
  private
    FTransport: TDCTransport;
    FNextID: UInt64;
    FLock: TCriticalSection;
    FResponses: TResponseMap;
    FEvents: TEventMap;
    FReaderThread: TRpcReaderThread;
    procedure ReaderExecute;
    function NextID: UInt64;
    procedure SendRequest(const AMethodName: string; Params: TJSONArray; ReqID: UInt64);
    function WaitForResponse(ReqID: UInt64): TJSONData;
  public
    constructor Create(ATransport: TDCTransport);
    destructor Destroy; override;
    procedure Call(const AMethodName: string; Params: TJSONArray);
    function CallResult(const AMethodName: string; Params: TJSONArray): TJSONData;
  end;

implementation

{ TRpcReaderThread }

constructor TRpcReaderThread.Create(ARpc: TRpc);
begin
  inherited Create(True); // create suspended
  FRpc := ARpc;
  FreeOnTerminate := False;
  Start;
end;

procedure TRpcReaderThread.Execute;
begin
  FRpc.ReaderExecute;
end;

{ TRpc }

constructor TRpc.Create(ATransport: TDCTransport);
begin
  inherited Create;
  FTransport := ATransport;
  FNextID := 0;
  FLock := TCriticalSection.Create;
  FResponses := TResponseMap.Create;
  FEvents := TEventMap.Create;
  FReaderThread := TRpcReaderThread.Create(Self);
end;

destructor TRpc.Destroy;
begin
  FReaderThread.Terminate;
  FReaderThread.WaitFor;
  FReaderThread.Free;
  FResponses.Free;
  FEvents.Free;
  FLock.Free;
  inherited Destroy;
end;

function TRpc.NextID: UInt64;
begin
  FLock.Enter;
  try
    Inc(FNextID);
    Result := FNextID;
  finally
    FLock.Leave;
  end;
end;

procedure TRpc.SendRequest(const AMethodName: string; Params: TJSONArray; ReqID: UInt64);
var
  Obj: TJSONObject;
  JSONStr: string;
begin
  Obj := TJSONObject.Create;
  try
    Obj.Add('jsonrpc', '2.0');
    Obj.Add('id', TJSONIntegerNumber.Create(ReqID));
    Obj.Add('method', AMethodName);
    Obj.Add('params', Params);
    JSONStr := Obj.AsJSON;
  finally
    // Obj.Free also frees Params (added via Add) — caller must NOT free it
    Obj.Free;
  end;
  FTransport.WriteLine(RawByteString(JSONStr));
end;

procedure TRpc.Call(const AMethodName: string; Params: TJSONArray);
var
  ID: UInt64;
  Resp: TJSONData;
begin
  ID := NextID;
  SendRequest(AMethodName, Params, ID); // Params is freed by SendRequest
  Resp := WaitForResponse(ID);
  Resp.Free;
end;

function TRpc.CallResult(const AMethodName: string; Params: TJSONArray): TJSONData;
var
  ID: UInt64;
begin
  ID := NextID;
  SendRequest(AMethodName, Params, ID); // Params is freed by SendRequest
  Result := WaitForResponse(ID);
end;

function TRpc.WaitForResponse(ReqID: UInt64): TJSONData;
var
  RespEvent: TEvent;
  FullResp: TJSONData;
  ErrData: TJSONData;
begin
  RespEvent := TEvent.Create(nil, True, False, '');
  FLock.Enter;
  try
    FEvents.Add(ReqID, RespEvent);
  finally
    FLock.Leave;
  end;
  RespEvent.WaitFor(INFINITE);
  FLock.Enter;
  try
    if not FResponses.TryGetData(ReqID, FullResp) then
      raise Exception.CreateFmt('No response for request %d', [ReqID]);
    FResponses.Remove(ReqID);
    FEvents.Remove(ReqID);
  finally
    FLock.Leave;
    RespEvent.Free;
  end;
  // Extract 'result' or raise on 'error'
  if not (FullResp is TJSONObject) then
    raise Exception.Create('Invalid JSON-RPC response');
  ErrData := (FullResp as TJSONObject).Find('error');
  if Assigned(ErrData) then
  begin
    Result := nil; // signal no result
    try
      Result := ErrData.Clone;
    finally
      FullResp.Free;
    end;
    raise Exception.Create('RPC error: ' + Result.AsJSON);
  end;
  Result := (FullResp as TJSONObject).Find('result');
  if not Assigned(Result) then
  begin
    // result is null/missing — clone a null
    Result := TJSONNull.Create;
    FullResp.Free;
  end
  else
  begin
    // Extract ownership: clone result, free full response
    Result := Result.Clone;
    FullResp.Free;
  end;
end;

procedure TRpc.ReaderExecute;
var
  Line: RawByteString;
  JSONObj: TJSONData;
  RespID: UInt64;
  RespEvent: TEvent;
  IDData: TJSONData;
begin
  while not FReaderThread.Terminated do
  begin
    Line := FTransport.ReadLine;
    if Line = '' then Continue;
    JSONObj := nil;
    try
      JSONObj := GetJSON(string(Line));
    except
      on E: Exception do
      begin
        if Assigned(JSONObj) then JSONObj.Free;
        JSONObj := nil;
      end;
    end;
    if JSONObj = nil then Continue;
    try
      if not (JSONObj is TJSONObject) then
      begin
        JSONObj.Free;
        Continue;
      end;
      IDData := (JSONObj as TJSONObject).Find('id');
      if IDData = nil then
      begin
        JSONObj.Free;
        Continue;
      end;
      RespID := UInt64(IDData.AsInt64);
      FLock.Enter;
      try
        FResponses.Add(RespID, JSONObj);
        if FEvents.TryGetData(RespID, RespEvent) then
          RespEvent.SetEvent;
      finally
        FLock.Leave;
      end;
    except
      on E: Exception do
        JSONObj.Free;
    end;
  end;
end;

end.
