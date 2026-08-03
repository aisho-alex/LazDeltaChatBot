unit dcauth;

{ Authorization gate for the bot.
  When BOT_AUTH_CODE is set, only contacts that have sent
  "/start <BOT_AUTH_CODE>" are allowed to talk to the bot. Authorized
  contact ids are persisted to BOT_AUTH_FILE (default accounts/authorized.txt)
  so the access survives restarts.

  Env vars:
    BOT_AUTH_CODE  secret phrase; empty = authorization disabled (open bot)
    BOT_AUTH_FILE  where authorized contact ids are stored (one per line)
}

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fgl;

type
  TContactSet = specialize TFPGMap<UInt64, Boolean>;

  TAuthStore = class
  private
    FCode: string;
    FPath: string;
    FUsers: TContactSet;
    procedure Load;
    procedure Save;
  public
    constructor Create;
    destructor Destroy; override;
    function Enabled: Boolean;
    function IsAuthorized(ContactId: UInt64): Boolean;
    procedure Authorize(ContactId: UInt64);
    function Count: Integer;
    property Code: string read FCode;
    property Path: string read FPath;
  end;

implementation

constructor TAuthStore.Create;
begin
  inherited Create;
  FCode := GetEnvironmentVariable('BOT_AUTH_CODE');
  FPath := GetEnvironmentVariable('BOT_AUTH_FILE');
  if FPath = '' then
    FPath := 'accounts' + PathDelim + 'authorized.txt';
  FUsers := TContactSet.Create;
  Load;
end;

destructor TAuthStore.Destroy;
begin
  FUsers.Free;
  inherited Destroy;
end;

function TAuthStore.Enabled: Boolean;
begin
  Result := FCode <> '';
end;

function TAuthStore.Count: Integer;
begin
  Result := FUsers.Count;
end;

procedure TAuthStore.Load;
var
  L: TStringList;
  i: Integer;
  Id: Int64;
begin
  if not FileExists(FPath) then Exit;
  L := TStringList.Create;
  try
    L.LoadFromFile(FPath);
    for i := 0 to L.Count - 1 do
    begin
      Id := StrToInt64Def(Trim(L[i]), -1);
      if (Id > 0) and (FUsers.IndexOf(UInt64(Id)) < 0) then
        FUsers.Add(UInt64(Id), True);
    end;
  finally
    L.Free;
  end;
end;

procedure TAuthStore.Save;
var
  L: TStringList;
  i: Integer;
begin
  ForceDirectories(ExtractFilePath(FPath));
  L := TStringList.Create;
  try
    for i := 0 to FUsers.Count - 1 do
      L.Add(IntToStr(FUsers.Keys[i]));
    L.SaveToFile(FPath);
  finally
    L.Free;
  end;
end;

function TAuthStore.IsAuthorized(ContactId: UInt64): Boolean;
begin
  Result := FUsers.IndexOf(ContactId) >= 0;
end;

procedure TAuthStore.Authorize(ContactId: UInt64);
begin
  if FUsers.IndexOf(ContactId) < 0 then
  begin
    FUsers.Add(ContactId, True);
    Save;
  end;
end;

end.
