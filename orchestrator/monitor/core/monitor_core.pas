unit monitor_core;

{ UI-независимое ядро монитора демонов: типы инвентаря + загрузчик daemons.json.
  Не зависит от LCL/Pixie — линкуется и CLI (FPC), и GUI (Lazarus). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils;

type
  TDaemonInventoryItem = record
    Name        : string;
    Kind        : string;   { fpc | python | sherpa }
    Host        : string;
    Port        : Integer;
    WsResource  : string;
    ModelName   : string;
    HealthKind  : string;   { ws | port | process }
    StartScript : string;   { относительно корня проекта }
    StopScript  : string;
  end;

  TDaemonInventory = array of TDaemonInventoryItem;

function    emptyDaemonInventoryItem: TDaemonInventoryItem;
function    loadDaemonInventory(const aPath: string): TDaemonInventory;
function    findDaemon(
              const aInventory: TDaemonInventory;
              const aName: string;
              out aItem: TDaemonInventoryItem
            ): Boolean;

implementation

uses
  Classes,
  fpjson,
  jsonparser;

function loadTextFileUtf8(const aPath: string): string;
var
  stream: TFileStream;
  raw: RawByteString;
begin
  Result := '';
  stream := TFileStream.Create(aPath, fmOpenRead or fmShareDenyNone);
  try
    if stream.Size > 0 then
    begin
      SetLength(raw, stream.Size);
      stream.ReadBuffer(raw[1], stream.Size);
      SetCodePage(raw, 65001, False);
      Result := raw;
    end;
  finally
    stream.Free;
  end;
end;

function jsonStringOf(const aObject: TJSONObject; const aName: string; const aDefault: string = ''): string;
var
  data: TJSONData;
begin
  Result := aDefault;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsString;
end;

function jsonIntOf(const aObject: TJSONObject; const aName: string; aDefault: Integer = 0): Integer;
var
  data: TJSONData;
begin
  Result := aDefault;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsInteger;
end;

function emptyDaemonInventoryItem: TDaemonInventoryItem;
begin
  Result.Name := '';
  Result.Kind := '';
  Result.Host := '127.0.0.1';
  Result.Port := 0;
  Result.WsResource := '/';
  Result.ModelName := '';
  Result.HealthKind := 'ws';
  Result.StartScript := '';
  Result.StopScript := '';
end;

function parseDaemonItem(const aObject: TJSONObject): TDaemonInventoryItem;
begin
  Result := emptyDaemonInventoryItem;
  Result.Name := Trim(jsonStringOf(aObject, 'name'));
  Result.Kind := Trim(jsonStringOf(aObject, 'kind'));
  Result.Host := Trim(jsonStringOf(aObject, 'host', '127.0.0.1'));
  Result.Port := jsonIntOf(aObject, 'port', 0);
  Result.WsResource := Trim(jsonStringOf(aObject, 'ws_resource', '/'));
  Result.ModelName := Trim(jsonStringOf(aObject, 'model_name'));
  Result.HealthKind := Trim(jsonStringOf(aObject, 'health', 'ws'));
  Result.StartScript := Trim(jsonStringOf(aObject, 'start_script'));
  Result.StopScript := Trim(jsonStringOf(aObject, 'stop_script'));
end;

function loadDaemonInventory(const aPath: string): TDaemonInventory;
var
  data: TJSONData;
  root: TJSONObject;
  arr: TJSONData;
  list: TJSONArray;
  idx: Integer;
  count: Integer;
begin
  SetLength(Result, 0);
  if not FileExists(aPath) then
    raise Exception.CreateFmt('daemon inventory not found: %s', [aPath]);

  data := GetJSON(loadTextFileUtf8(aPath));
  try
    if data.JSONType <> jtObject then
      raise Exception.Create('daemons.json root must be a JSON object');

    root := TJSONObject(data);
    arr := root.Find('daemons');
    if (arr = nil) or (arr.JSONType <> jtArray) then
      raise Exception.Create('daemons.json must contain a "daemons" array');

    list := TJSONArray(arr);
    SetLength(Result, list.Count);
    count := 0;
    for idx := 0 to list.Count - 1 do
    begin
      if list.Items[idx].JSONType <> jtObject then
        Continue;

      Result[count] := parseDaemonItem(TJSONObject(list.Items[idx]));
      if Result[count].Name = '' then
        raise Exception.CreateFmt('daemons.json item #%d has empty name', [idx]);
      if Result[count].Port <= 0 then
        raise Exception.CreateFmt('daemons.json item "%s" has invalid port', [Result[count].Name]);
      Inc(count);
    end;
    SetLength(Result, count);
  finally
    data.Free;
  end;
end;

function findDaemon(
  const aInventory: TDaemonInventory;
  const aName: string;
  out aItem: TDaemonInventoryItem
): Boolean;
var
  idx: Integer;
begin
  Result := False;
  aItem := emptyDaemonInventoryItem;
  for idx := 0 to High(aInventory) do
    if SameText(aInventory[idx].Name, aName) then
    begin
      aItem := aInventory[idx];
      Exit(True);
    end;
end;

end.
