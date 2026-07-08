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
function runDaemonsStart(const aConfigPath, aName: string; aTimeoutMs: Integer; aJson: Boolean): Integer;
function runDaemonsStop(const aConfigPath, aName: string; aJson: Boolean): Integer;
function runDaemonsRestart(const aConfigPath, aName: string; aTimeoutMs: Integer; aJson: Boolean): Integer;

implementation

uses
  SysUtils, Classes, fpjson, echoctl_config, echoctl_common, echoctl_schema, echoctl_launch;

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
  Result := SameText(aEngine, 'whisper') or SameText(aEngine, 'vosk') or
            SameText(aEngine, 'diarization');
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

{ Диапазон портов движка для авто-аллокации (whisper 78xx, vosk 77xx, diarization 79xx). }
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
  else if SameText(aEngine, 'diarization') then
  begin
    aLo := 7900;
    aHi := 7999;
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
      Exit(fail('unknown engine: ' + aSpec.Engine + ' (known: whisper, vosk, diarization)'));
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

{ ---- lifecycle (start/stop/restart) ---- }

function daemonExePath(const aRepoRoot, aEngine: string): string;
begin
  if SameText(aEngine, 'whisper') then
    Result := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'whisperdaemon' + PathDelim + 'build' + PathDelim + 'x64' +
      PathDelim + 'WhisperDaemon.exe'
  else if SameText(aEngine, 'vosk') then
    Result := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'voskdaemon' + PathDelim + 'build' + PathDelim + 'x64' +
      PathDelim + 'VoskDaemon.exe'
  else if SameText(aEngine, 'diarization') then
    Result := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'build' + PathDelim + 'x64' + PathDelim + 'DiarizationDaemon.exe'
  else
    Result := '';
end;

function daemonLogDir(const aRepoRoot, aEngine: string): string;
begin
  { diarization живёт глубже: services/diarizationdaemon/sherpa/logs }
  if SameText(aEngine, 'diarization') then
    Result := IncludeTrailingPathDelimiter(aRepoRoot) + 'services' + PathDelim +
      'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim + 'logs'
  else if SameText(aEngine, 'vosk') then
    Result := IncludeTrailingPathDelimiter(aRepoRoot) + 'services' + PathDelim +
      'voskdaemon' + PathDelim + 'logs'
  else
    Result := IncludeTrailingPathDelimiter(aRepoRoot) + 'services' + PathDelim +
      'whisperdaemon' + PathDelim + 'logs';
end;

function boolEnv(aValue: Boolean): string;
begin
  if aValue then
    Result := '1'
  else
    Result := '0';
end;

function floatEnv(aValue: Double): string;
var
  fs: TFormatSettings;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := FloatToStr(aValue, fs);
end;

procedure buildDaemonEnv(const aRepoRoot, aEngine: string; aSettings: TJSONObject; aEnv: TStringList);
begin
  if SameText(aEngine, 'whisper') then
  begin
    aEnv.Values['WHISPER_MODELS_ROOT'] := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'whisperdaemon' + PathDelim + 'models';
    if aSettings <> nil then
    begin
      if aSettings.Find('vad') <> nil then
        aEnv.Values['WHISPER_VAD'] := boolEnv(aSettings.Get('vad', True));
      if aSettings.Find('vad_threshold') <> nil then
        aEnv.Values['WHISPER_VAD_THRESHOLD'] := floatEnv(aSettings.Get('vad_threshold', 0.4));
      if aSettings.Find('vad_speech_pad_ms') <> nil then
        aEnv.Values['WHISPER_VAD_SPEECH_PAD_MS'] := IntToStr(aSettings.Get('vad_speech_pad_ms', 200));
      if aSettings.Find('no_speech_thold') <> nil then
        aEnv.Values['WHISPER_NO_SPEECH_THOLD'] := floatEnv(aSettings.Get('no_speech_thold', 0.6));
      if aSettings.Find('entropy_thold') <> nil then
        aEnv.Values['WHISPER_ENTROPY_THOLD'] := floatEnv(aSettings.Get('entropy_thold', 2.4));
    end;
  end
  else if SameText(aEngine, 'diarization') then
  begin
    { diarization: sherpa-dll + пути к ONNX-моделям + тюнинг — всё через env (демон их читает). }
    aEnv.Values['SHERPA_DLL_PATH'] := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'vendors' + PathDelim + 'sherpa-onnx' + PathDelim + 'sherpa-onnx.dll';
    aEnv.Values['DIARIZE_SEG_MODEL'] := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'models' + PathDelim + 'segmentation.onnx';
    aEnv.Values['DIARIZE_EMB_MODEL'] := IncludeTrailingPathDelimiter(aRepoRoot) +
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'models' + PathDelim + 'embedding.onnx';
    if aSettings <> nil then
    begin
      if aSettings.Find('num_speakers') <> nil then
        aEnv.Values['DIARIZE_NUM_SPEAKERS'] := IntToStr(aSettings.Get('num_speakers', -1));
      if aSettings.Find('cluster_threshold') <> nil then
        aEnv.Values['DIARIZE_CLUSTER_THRESHOLD'] := floatEnv(aSettings.Get('cluster_threshold', 0.5));
      if aSettings.Find('min_duration_on') <> nil then
        aEnv.Values['DIARIZE_MIN_DURATION_ON'] := floatEnv(aSettings.Get('min_duration_on', 0.2));
      if aSettings.Find('min_duration_off') <> nil then
        aEnv.Values['DIARIZE_MIN_DURATION_OFF'] := floatEnv(aSettings.Get('min_duration_off', 0.5));
    end;
  end;
  { vosk: VOSK_MODELS_ROOT — оставляем дефолт демона (C:\var\vosk), если не задан в окружении. }
end;

function buildDaemonArgs(const aModel, aHost: string; aPort: Integer;
  const aEngine: string; aSettings: TJSONObject): string;
begin
  if SameText(aEngine, 'diarization') then
    { diarization не принимает --model-name; sherpa-dll/модели/настройки идут через env. }
    Exit('--host ' + aHost + ' --port ' + IntToStr(aPort));

  Result := '--model-name "' + aModel + '" --host ' + aHost + ' --port ' + IntToStr(aPort);
  if SameText(aEngine, 'whisper') and (aSettings <> nil) then
  begin
    if aSettings.Find('gpu') <> nil then
    begin
      if aSettings.Get('gpu', False) then
        Result := Result + ' --gpu'
      else
        Result := Result + ' --no-gpu';
    end;
    if aSettings.Find('gpu_device') <> nil then
      Result := Result + ' --gpu-device ' + IntToStr(aSettings.Get('gpu_device', 0));
  end;
end;

{ Копирование файла с перезаписью через потоки (без Windows-зависимости). }
function copyFileOverwrite(const aSrc, aDst: string): Boolean;
var
  src, dst: TFileStream;
begin
  Result := False;
  if not FileExists(aSrc) then
    Exit;
  try
    src := TFileStream.Create(aSrc, fmOpenRead or fmShareDenyNone);
    try
      dst := TFileStream.Create(aDst, fmCreate);
      try
        if src.Size > 0 then
          dst.CopyFrom(src, src.Size);
        Result := True;
      finally
        dst.Free;
      end;
    finally
      src.Free;
    end;
  except
    Result := False;
  end;
end;

{ diarization: sherpa-onnx подгружает ORT DLL из каталога exe → стейджим их из vendors в
  build/x64 (как run-скрипт copy /y). Стейджим только отсутствующие: если уже на месте
  (возможно, залочены запущенным инстансом) — не трогаем. False, если vendor-DLL нет вовсе. }
function stageDiarizationRuntime(const aRepoRoot: string): Boolean;
var
  vend, bin: string;

  function stageOne(const aName: string): Boolean;
  begin
    if FileExists(bin + aName) then
      Exit(True);
    Result := copyFileOverwrite(vend + aName, bin + aName);
  end;

begin
  vend := IncludeTrailingPathDelimiter(aRepoRoot) + 'services' + PathDelim +
    'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim + 'vendors' + PathDelim +
    'sherpa-onnx' + PathDelim;
  bin := IncludeTrailingPathDelimiter(aRepoRoot) + 'services' + PathDelim +
    'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim + 'build' + PathDelim + 'x64' + PathDelim;
  Result := stageOne('onnxruntime.dll') and stageOne('onnxruntime_providers_shared.dll');
end;

{ Убить <Engine>Daemon.exe, слушающий aPort (владелец listening-сокета = сам демон). }
function stopDaemonByPort(aPort: Integer): Boolean;
var
  comLine: string;
begin
  comLine := '-NoProfile -Command "Get-NetTCPConnection -LocalPort ' + IntToStr(aPort) +
    ' -State Listen -ErrorAction SilentlyContinue | ForEach-Object { Stop-Process -Id $_.OwningProcess -Force }"';
  Result := ExecuteProcess('powershell.exe', comLine) = 0;
end;

procedure reportStart(aJson: Boolean; const aName, aStatus, aHost: string; aPort: Integer);
var
  o: TJSONObject;
begin
  if aJson then
  begin
    o := TJSONObject.Create;
    try
      o.Add('name', aName);
      o.Add('status', aStatus);
      o.Add('host', aHost);
      o.Add('port', aPort);
      WriteLn(o.FormatJSON());
    finally
      o.Free;
    end;
  end
  else
    WriteLn(Format('%s %s (%s:%d)', [aStatus, aName, aHost, aPort]));
end;

procedure reportStop(aJson: Boolean; const aName, aStatus: string; aPort: Integer);
var
  o: TJSONObject;
begin
  if aJson then
  begin
    o := TJSONObject.Create;
    try
      o.Add('name', aName);
      o.Add('status', aStatus);
      o.Add('port', aPort);
      WriteLn(o.FormatJSON());
    finally
      o.Free;
    end;
  end
  else
    WriteLn(Format('%s %s (:%d)', [aStatus, aName, aPort]));
end;

function findInstance(aConfig: TJSONObject; const aName: string): TJSONObject;
var
  ws: TJSONObject;
begin
  ws := daemonsObject(aConfig);
  if (ws <> nil) and (ws.IndexOfName(aName) >= 0) then
    Result := ws.Objects[aName]
  else
    Result := nil;
end;

function runDaemonsStart(const aConfigPath, aName: string; aTimeoutMs: Integer; aJson: Boolean): Integer;
var
  config, inst, settings: TJSONObject;
  node: TJSONData;
  repoRoot, engine, host, model, exePath, logDir, logPath, args, err, detail: string;
  port, pid: Integer;
  env: TStringList;
  outcome: TWarmupOutcome;
begin
  config := loadConfigObject(aConfigPath);
  env := TStringList.Create;
  try
    inst := findInstance(config, aName);
    if inst = nil then
      Exit(fail('no such instance: ' + aName));
    engine := inst.Get('engine', '');
    host := inst.Get('host', '127.0.0.1');
    port := inst.Get('port', 0);
    model := inst.Get('model_name', '');
    node := inst.Find('settings');
    if (node <> nil) and (node is TJSONObject) then
      settings := TJSONObject(node)
    else
      settings := nil;

    repoRoot := resolveRepoRoot;
    exePath := daemonExePath(repoRoot, engine);
    if exePath = '' then
      Exit(fail('unknown engine: ' + engine));
    if not FileExists(exePath) then
      Exit(fail('daemon exe not built: ' + exePath));

    if isPortOpen(host, port) then
    begin
      reportStart(aJson, aName, 'already-running', host, port);
      Exit(EXIT_OK);
    end;

    logDir := daemonLogDir(repoRoot, engine);
    ForceDirectories(logDir);
    logPath := IncludeTrailingPathDelimiter(logDir) + aName + '.log';
    SysUtils.DeleteFile(logPath);

    buildDaemonEnv(repoRoot, engine, settings, env);
    args := buildDaemonArgs(model, host, port, engine, settings);

    { diarization: sherpa-onnx требует ORT DLL рядом с exe — стейджим перед стартом. }
    if SameText(engine, 'diarization') then
      if not stageDiarizationRuntime(repoRoot) then
        Exit(fail('failed to stage sherpa ONNX runtime DLLs (build + download_sherpa_assets first?)'));

    if not spawnDaemon(exePath, args, repoRoot, logPath, env, pid, err) then
      Exit(fail('spawn failed: ' + err));

    outcome := waitWarmup(logPath, aTimeoutMs, detail);
    if outcome = woReady then
    begin
      waitPortOpen(host, port, 5000);
      { dev (ECHOSCRIPT_DEV=1 + есть wt): открыть echotail-вкладку на лог. Демон без окна. }
      if devTailEnabled then
        openLogTab(repoRoot, aName, logPath);
      reportStart(aJson, aName, 'started', host, port);
      Result := EXIT_OK;
    end
    else
    begin
      writeErr(Format('echoctl: %s did not become ready (%s). Log tail:', [aName, detail]));
      writeErr(logTail(logPath, 700));
      Result := EXIT_RUNTIME;
    end;
  finally
    env.Free;
    config.Free;
  end;
end;

function runDaemonsStop(const aConfigPath, aName: string; aJson: Boolean): Integer;
var
  config, inst: TJSONObject;
  host: string;
  port: Integer;
begin
  config := loadConfigObject(aConfigPath);
  try
    inst := findInstance(config, aName);
    if inst = nil then
      Exit(fail('no such instance: ' + aName));
    host := inst.Get('host', '127.0.0.1');
    port := inst.Get('port', 0);

    stopDaemonByPort(port);
    if waitPortClosed(host, port, 10000) then
    begin
      reportStop(aJson, aName, 'stopped', port);
      Result := EXIT_OK;
    end
    else
    begin
      writeErr(Format('echoctl: %s still listening on :%d after stop', [aName, port]));
      Result := EXIT_RUNTIME;
    end;
  finally
    config.Free;
  end;
end;

function runDaemonsRestart(const aConfigPath, aName: string; aTimeoutMs: Integer; aJson: Boolean): Integer;
var
  config, inst: TJSONObject;
  host: string;
  port: Integer;
begin
  { Лучший-эффорт стоп (если инстанс есть и слушает), затем старт (он и отчитается). }
  config := loadConfigObject(aConfigPath);
  try
    inst := findInstance(config, aName);
    if inst <> nil then
    begin
      host := inst.Get('host', '127.0.0.1');
      port := inst.Get('port', 0);
      if isPortOpen(host, port) then
      begin
        stopDaemonByPort(port);
        waitPortClosed(host, port, 10000);
      end;
    end;
  finally
    config.Free;
  end;
  Result := runDaemonsStart(aConfigPath, aName, aTimeoutMs, aJson);
end;

end.
