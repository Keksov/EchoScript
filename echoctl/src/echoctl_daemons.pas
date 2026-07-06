unit echoctl_daemons;

{ Команды группы daemons. На шаге DF0.4 — только `list` (чтение ws_daemons из
  config.json → JSON-массив или человекочитаемая таблица). CRUD/lifecycle — далее. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, fpjson;

{ Печатает инстансы ws_daemons. aJson=True → JSON-массив, иначе таблица. Возврат 0. }
function runDaemonsList(aConfig: TJSONObject; aJson: Boolean): Integer;

implementation

function daemonsObject(aConfig: TJSONObject): TJSONObject;
var
  node: TJSONData;
begin
  node := aConfig.Find('ws_daemons');
  if (node <> nil) and (node is TJSONObject) then
    Result := TJSONObject(node)
  else
    Result := nil;
end;

function instanceToJson(const aName: string; aInst: TJSONObject): TJSONObject;
var
  settings: TJSONData;
begin
  Result := TJSONObject.Create;
  Result.Add('name', aName);
  Result.Add('engine', aInst.Get('engine', ''));
  Result.Add('language', aInst.Get('language', ''));
  Result.Add('host', aInst.Get('host', ''));
  Result.Add('port', aInst.Get('port', 0));
  Result.Add('model_name', aInst.Get('model_name', ''));
  settings := aInst.Find('settings');
  if (settings <> nil) and (settings is TJSONObject) then
    Result.Add('settings', TJSONObject(settings.Clone))
  else
    Result.Add('settings', TJSONObject.Create);
end;

function listJson(aWs: TJSONObject): Integer;
var
  arr: TJSONArray;
  i: Integer;
begin
  arr := TJSONArray.Create;
  try
    if aWs <> nil then
      for i := 0 to aWs.Count - 1 do
        arr.Add(instanceToJson(aWs.Names[i], aWs.Objects[aWs.Names[i]]));
    WriteLn(arr.FormatJSON());
  finally
    arr.Free;
  end;
  Result := 0;
end;

function listTable(aWs: TJSONObject): Integer;
const
  ROW = '%-18s %-8s %-5s %-18s %s';
var
  i: Integer;
  name: string;
  inst: TJSONObject;
begin
  WriteLn(Format(ROW, ['NAME', 'ENGINE', 'LANG', 'ENDPOINT', 'MODEL']));
  if aWs <> nil then
    for i := 0 to aWs.Count - 1 do
    begin
      name := aWs.Names[i];
      inst := aWs.Objects[name];
      WriteLn(Format(ROW,
        [name,
         inst.Get('engine', ''),
         inst.Get('language', ''),
         inst.Get('host', '') + ':' + IntToStr(inst.Get('port', 0)),
         inst.Get('model_name', '')]));
    end;
  Result := 0;
end;

function runDaemonsList(aConfig: TJSONObject; aJson: Boolean): Integer;
var
  ws: TJSONObject;
begin
  ws := daemonsObject(aConfig);
  if aJson then
    Result := listJson(ws)
  else
    Result := listTable(ws);
end;

end.
