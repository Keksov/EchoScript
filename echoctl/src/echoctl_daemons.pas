unit echoctl_daemons;

{ Команды группы daemons: list (DF0.4) и add (DF1.1). Каждая команда сама грузит
  config.json по пути и, если мутирует, сохраняет атомарно (echoctl_config). }

{$mode objfpc}{$H+}

interface

type
  { Параметры создания инстанса (собираются CLI из аргументов). }
  TAddSpec = record
    Name: string;
    Engine: string;
    Language: string;
    Host: string;
    ModelName: string;
    Port: Integer;
  end;

function runDaemonsList(const aConfigPath: string; aJson: Boolean): Integer;
function runDaemonsAdd(const aConfigPath: string; const aSpec: TAddSpec; aJson: Boolean): Integer;
function runDaemonsRemove(const aConfigPath, aName: string; aJson: Boolean): Integer;
function runDaemonsEdit(const aConfigPath, aName, aNewModel: string; aNewPort: Integer;
  const aSets: array of string; aJson: Boolean): Integer;

implementation

uses
  SysUtils, fpjson, echoctl_config, echoctl_common, echoctl_schema;

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

function ensureDaemonsObject(aConfig: TJSONObject): TJSONObject;
begin
  Result := daemonsObject(aConfig);
  if Result = nil then
  begin
    Result := TJSONObject.Create;
    aConfig.Add('ws_daemons', Result);
  end;
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

function isKnownEngine(const aEngine: string): Boolean;
begin
  Result := SameText(aEngine, 'whisper') or SameText(aEngine, 'vosk');
end;

{ Модель считается известной, если это ключ в config.models (источник идентичности
  моделей в системе). DF2.1 расширит проверку манифестом/наличием на диске. }
function modelKnown(aConfig: TJSONObject; const aModel: string): Boolean;
var
  node: TJSONData;
begin
  node := aConfig.Find('models');
  Result := (node <> nil) and (node is TJSONObject) and
            (TJSONObject(node).Find(aModel) <> nil);
end;

function portInUse(aWs: TJSONObject; aPort: Integer; const aExcept: string): Boolean;
var
  i: Integer;
  nm: string;
begin
  if aWs <> nil then
    for i := 0 to aWs.Count - 1 do
    begin
      nm := aWs.Names[i];
      if SameText(nm, aExcept) then
        Continue;
      if aWs.Objects[nm].Get('port', -1) = aPort then
        Exit(True);
    end;
  Result := False;
end;

{ Диапазон портов движка для авто-аллокации (совпадает с текущими: whisper 78xx, vosk 77xx). }
function enginePortRange(const aEngine: string; out aLo, aHi: Integer): Boolean;
begin
  Result := True;
  if SameText(aEngine, 'whisper') then
  begin
    aLo := 7801;
    aHi := 7899;
  end
  else if SameText(aEngine, 'vosk') then
  begin
    aLo := 7701;
    aHi := 7799;
  end
  else
    Result := False;
end;

{ Первый свободный порт в диапазоне движка; -1, если диапазон исчерпан/движок неизвестен. }
function allocatePort(aWs: TJSONObject; const aEngine: string): Integer;
var
  lo, hi, p: Integer;
begin
  if not enginePortRange(aEngine, lo, hi) then
    Exit(-1);
  for p := lo to hi do
    if not portInUse(aWs, p, '') then
      Exit(p);
  Result := -1;
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
  Result := EXIT_OK;
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
  Result := EXIT_OK;
end;

function runDaemonsList(const aConfigPath: string; aJson: Boolean): Integer;
var
  config: TJSONObject;
begin
  config := loadConfigObject(aConfigPath);
  try
    if aJson then
      Result := listJson(daemonsObject(config))
    else
      Result := listTable(daemonsObject(config));
  finally
    config.Free;
  end;
end;

function defaultName(const aSpec: TAddSpec): string;
begin
  if aSpec.Name <> '' then
    Result := aSpec.Name
  else if aSpec.Language <> '' then
    Result := aSpec.Engine + '_' + aSpec.Language
  else
    Result := aSpec.Engine;
end;

function runDaemonsAdd(const aConfigPath: string; const aSpec: TAddSpec; aJson: Boolean): Integer;
var
  config, ws, inst, created: TJSONObject;
  name, host: string;
  port: Integer;
begin
  config := loadConfigObject(aConfigPath);
  try
    if aSpec.Engine = '' then
      Exit(fail('--engine is required'));
    if not isKnownEngine(aSpec.Engine) then
      Exit(fail('unknown engine: ' + aSpec.Engine + ' (known: whisper, vosk)'));
    if aSpec.ModelName = '' then
      Exit(fail('--model is required'));
    if not modelKnown(config, aSpec.ModelName) then
      Exit(fail('unknown model: ' + aSpec.ModelName + ' (not a key in config.models)'));

    ws := ensureDaemonsObject(config);
    name := defaultName(aSpec);
    if ws.Find(name) <> nil then
      Exit(fail('instance already exists: ' + name + ' (use --name)'));

    port := aSpec.Port;
    if port <= 0 then
    begin
      port := allocatePort(ws, aSpec.Engine);
      if port < 0 then
        Exit(fail('no free port in range for engine ' + aSpec.Engine));
    end
    else
    begin
      if port > 65535 then
        Exit(fail('--port must be 1..65535'));
      if portInUse(ws, port, '') then
        Exit(fail('port already in use: ' + IntToStr(port)));
    end;

    if aSpec.Host <> '' then
      host := aSpec.Host
    else
      host := '127.0.0.1';

    inst := TJSONObject.Create;
    inst.Add('host', host);
    inst.Add('port', port);
    inst.Add('engine', aSpec.Engine);
    inst.Add('language', aSpec.Language);
    inst.Add('model_name', aSpec.ModelName);
    ws.Add(name, inst);

    saveConfigAtomic(aConfigPath, config);

    if aJson then
    begin
      created := instanceToJson(name, inst);
      try
        WriteLn(created.FormatJSON());
      finally
        created.Free;
      end;
    end
    else
      WriteLn(Format('added daemon %s (%s %s %s:%d %s)',
        [name, aSpec.Engine, aSpec.Language, host, port, aSpec.ModelName]));
    Result := EXIT_OK;
  finally
    config.Free;
  end;
end;

function runDaemonsRemove(const aConfigPath, aName: string; aJson: Boolean): Integer;
var
  config, ws, res: TJSONObject;
  idx: Integer;
begin
  if aName = '' then
    Exit(fail('instance name required (positional or --name)'));
  config := loadConfigObject(aConfigPath);
  try
    ws := daemonsObject(config);
    if ws <> nil then
      idx := ws.IndexOfName(aName)
    else
      idx := -1;
    if idx < 0 then
      Exit(fail('no such instance: ' + aName));

    ws.Delete(idx);
    saveConfigAtomic(aConfigPath, config);

    if aJson then
    begin
      res := TJSONObject.Create;
      try
        res.Add('removed', aName);
        WriteLn(res.FormatJSON());
      finally
        res.Free;
      end;
    end
    else
      WriteLn('removed daemon ', aName);
    Result := EXIT_OK;
  finally
    config.Free;
  end;
end;

function ensureSettings(aInst: TJSONObject): TJSONObject;
var
  node: TJSONData;
begin
  node := aInst.Find('settings');
  if (node <> nil) and (node is TJSONObject) then
    Result := TJSONObject(node)
  else
  begin
    Result := TJSONObject.Create;
    aInst.Add('settings', Result);
  end;
end;

{ Применяет один "key=value" к settings инстанса с валидацией по схеме движка. }
function applySet(aInst: TJSONObject; const aEngine, aPair: string; out aError: string): Boolean;
var
  eqPos, idx: Integer;
  key, rawVal: string;
  spec: TSettingSpec;
  jval: TJSONData;
  settings: TJSONObject;
begin
  eqPos := Pos('=', aPair);
  if eqPos < 1 then
  begin
    aError := 'bad --set (expected key=value): ' + aPair;
    Exit(False);
  end;
  key := Trim(Copy(aPair, 1, eqPos - 1));
  rawVal := Copy(aPair, eqPos + 1, MaxInt);
  if not findSettingSpec(aEngine, key, spec) then
  begin
    aError := 'unknown setting "' + key + '" for engine ' + aEngine +
      ' (allowed: ' + engineKeyList(aEngine) + ')';
    Exit(False);
  end;
  if not parseSettingValue(spec, rawVal, jval, aError) then
    Exit(False);
  settings := ensureSettings(aInst);
  idx := settings.IndexOfName(key);
  if idx >= 0 then
    settings.Delete(idx);
  settings.Add(key, jval);
  Result := True;
end;

function runDaemonsEdit(const aConfigPath, aName, aNewModel: string; aNewPort: Integer;
  const aSets: array of string; aJson: Boolean): Integer;
var
  config, ws, inst, created: TJSONObject;
  engine, err: string;
  i, idx: Integer;
  changed: Boolean;
begin
  if aName = '' then
    Exit(fail('instance name required (positional or --name)'));
  config := loadConfigObject(aConfigPath);
  try
    ws := daemonsObject(config);
    if ws <> nil then
      idx := ws.IndexOfName(aName)
    else
      idx := -1;
    if idx < 0 then
      Exit(fail('no such instance: ' + aName));

    inst := ws.Objects[aName];
    engine := inst.Get('engine', '');
    changed := False;

    if aNewModel <> '' then
    begin
      if not modelKnown(config, aNewModel) then
        Exit(fail('unknown model: ' + aNewModel + ' (not a key in config.models)'));
      inst.Strings['model_name'] := aNewModel;
      changed := True;
    end;

    if aNewPort >= 1 then
    begin
      if aNewPort > 65535 then
        Exit(fail('--port must be 1..65535'));
      if portInUse(ws, aNewPort, aName) then
        Exit(fail('port already in use: ' + IntToStr(aNewPort)));
      inst.Integers['port'] := aNewPort;
      changed := True;
    end;

    for i := 0 to High(aSets) do
    begin
      if not applySet(inst, engine, aSets[i], err) then
        Exit(fail(err));
      changed := True;
    end;

    if not changed then
      Exit(fail('nothing to edit; use --port/--model/--set key=value'));

    saveConfigAtomic(aConfigPath, config);

    if aJson then
    begin
      created := instanceToJson(aName, inst);
      try
        WriteLn(created.FormatJSON());
      finally
        created.Free;
      end;
    end
    else
      WriteLn('edited daemon ', aName);
    Result := EXIT_OK;
  finally
    config.Free;
  end;
end;

end.
