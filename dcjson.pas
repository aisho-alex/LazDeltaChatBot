unit dcjson;

{$mode objfpc}{$H+}

interface

uses
  fpjson;

type
  TOptionString = record
    HasValue: Boolean;
    Value: string;
  end;

function SomeStr(const S: string): TOptionString; inline;
function NoneStr: TOptionString; inline;
function OptionToJSON(const Opt: TOptionString): TJSONData; // returns TJSONString or TJSONNull
function JSONToOption(const Data: TJSONData): TOptionString;

implementation

function SomeStr(const S: string): TOptionString; inline;
begin
  Result.HasValue := True;
  Result.Value := S;
end;

function NoneStr: TOptionString; inline;
begin
  Result.HasValue := False;
  Result.Value := '';
end;

function OptionToJSON(const Opt: TOptionString): TJSONData;
begin
  if Opt.HasValue then
    Result := TJSONString.Create(Opt.Value)
  else
    Result := TJSONNull.Create;
end;

function JSONToOption(const Data: TJSONData): TOptionString;
begin
  if (Data=nil) or (Data is TJSONNull) then
    Result := NoneStr
  else
  begin
    Result.HasValue := True;
    Result.Value := Data.AsString;
  end;
end;

end.
