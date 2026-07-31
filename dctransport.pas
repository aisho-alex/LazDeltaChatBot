unit dctransport;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, Process;

type
  TDCTransport = class
  private
    FProcess: TProcess;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Open;
    procedure Close;
    function ReadLine: RawByteString;
    procedure WriteLine(const S: RawByteString);
    property Process: TProcess read FProcess;
  end;

implementation

constructor TDCTransport.Create;
begin
  inherited Create;
  FProcess := TProcess.Create(nil);
end;

destructor TDCTransport.Destroy;
begin
  Close;
  FProcess.Free;
  inherited Destroy;
end;

procedure TDCTransport.Open;
var
  BinPath: string;

  function FindInSnap: string;
  var
    SR: TSearchRec;
    BaseDir, NodeDir: string;
  Found: TStringList;
  begin
    Result := '';
    Found := TStringList.Create;
    try
      BaseDir := '/snap/deltachat-desktop';
      if FindFirst(BaseDir + '/*', faDirectory, SR) = 0 then
      begin
        repeat
          if (SR.Name <> '.') and (SR.Name <> '..') then
            Found.Add(SR.Name);
        until FindNext(SR) <> 0;
        FindClose(SR);
      end;
      // sort descending to get latest version first
      Found.Sort;
      Found.Sorted := True;
      while Found.Count > 0 do
      begin
        NodeDir := BaseDir + '/' + Found[Found.Count-1] +
                   '/resources/app/node_modules/@deltachat/stdio-rpc-server-linux-x64/deltachat-rpc-server';
        if FileExists(NodeDir) then
        begin
          Result := NodeDir;
          Break;
        end;
        Found.Delete(Found.Count-1);
      end;
    finally
      Found.Free;
    end;
  end;

begin
  if FProcess.Running then Exit;
  // 1. explicit override
  BinPath := GetEnvironmentVariable('DC_RPC_SERVER');
  // 2. in PATH (default)
  if BinPath = '' then
    BinPath := 'deltachat-rpc-server';
  // 3. fallback: search snap
  if not FileExists(BinPath) then
  begin
    BinPath := FindInSnap;
    if BinPath = '' then
      raise Exception.Create('deltachat-rpc-server not found. Set DC_RPC_SERVER env var to its path.');
  end;
  FProcess.Executable := BinPath;
  FProcess.Options := [poUsePipes, poNoConsole];
  FProcess.Execute;
end;

procedure TDCTransport.Close;
begin
  if Assigned(FProcess) and FProcess.Running then
    FProcess.Terminate(0);
end;

procedure TDCTransport.WriteLine(const S: RawByteString);
var
  Len: Integer;
  NL: Byte;
begin
  if not FProcess.Running then Exit;
  Len := Length(S);
  if Len > 0 then
    FProcess.Input.Write(Pointer(@S[1])^, Len);
  NL := 10;
  FProcess.Input.Write(NL, 1);
end;

function TDCTransport.ReadLine: RawByteString;
var
  B: Byte;
  N: Integer;
begin
  Result := '';
  if not FProcess.Running then Exit;
  while True do
  begin
    N := FProcess.Output.Read(B, 1);
    if N = 0 then Break;
    if B = 10 then Break;
    Result := Result + Chr(B);
  end;
end;

end.
