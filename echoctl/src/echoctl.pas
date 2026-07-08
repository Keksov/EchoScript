program echoctl;

{ echoctl — EchoScript daemon & model fleet control (FPC CLI).

  Единственный движок управления флотом демонов и моделями: CRUD инстансов
  ws_daemons, per-instance настройки, жизненный цикл моделей (download/delete),
  запуск/остановка демонов, правка настроек оркестратора. config.json —
  единственный писатель здесь (atomic temp+rename). UI/Bun — тонкая обёртка,
  вызывающая echoctl <cmd> --json.

  echoctl.pas — разбор аргументов и диспетчер групп/команд. Доменная логика — в
  echoctl_daemons / echoctl_models / echoctl_config; общие мелочи — echoctl_common. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  Types,
  echoctl_common,
  echoctl_config,
  echoctl_schema,
  echoctl_daemons,
  echoctl_models;

const
  ECHOCTL_VERSION = '0.1.0';

procedure printVersion;
begin
  WriteLn('echoctl ', ECHOCTL_VERSION);
end;

procedure printUsage;
begin
  WriteLn('echoctl ', ECHOCTL_VERSION, ' — EchoScript daemon & model fleet control');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  echoctl <group> <command> [options] [--json]');
  WriteLn;
  WriteLn('Groups & commands:');
  WriteLn('  daemons   list | add | remove | edit | start | stop | restart');
  WriteLn('  models    list | download | delete');
  WriteLn('  config    get | set | schema');
  WriteLn;
  WriteLn('daemons add --engine <e> --model <m> --port <n> [--host H] [--lang L] [--name NM]');
  WriteLn('models delete <id> [--dry-run] [--force]   (refuses if an instance references the model)');
  WriteLn;
  WriteLn('Other:');
  WriteLn('  echoctl version    print version and exit');
  WriteLn('  echoctl help       print this help and exit');
  WriteLn;
  WriteLn('Notes:');
  WriteLn('  --json            emit machine-readable JSON (for the control-panel wrapper)');
  WriteLn('  --config <path>   use a specific config.json (default: found near the exe)');
  WriteLn('  --manifest <path> use a specific models-manifest.json (default: found near the exe)');
end;

{ Наличие флага (напр. --json) в любой позиции. }
function hasFlag(const aName: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to ParamCount do
    if ParamStr(i) = aName then
      Exit(True);
  Result := False;
end;

{ Значение опции "--name value"; aDefault, если опция не задана. }
function optionValue(const aName, aDefault: string): string;
var
  i: Integer;
begin
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = aName then
      Exit(ParamStr(i + 1));
  Result := aDefault;
end;

{ Путь к активному config.json: --config override или поиск от exe. }
function activeConfigPath: string;
begin
  Result := optionValue('--config', resolveDefaultConfigPath);
end;

function activeManifestPath: string;
begin
  Result := optionValue('--manifest', findFileUpwards('models-manifest.json'));
end;

{ Таймаут ожидания warmup при start/restart, секунды → мс (по умолчанию 180с). }
function activeTimeoutMs: Integer;
begin
  Result := StrToIntDef(optionValue('--timeout', '180'), 180) * 1000;
end;

function doDaemonsList: Integer;
begin
  Result := runDaemonsList(activeConfigPath, hasFlag('--json'));
end;

{ collectSets определена ниже (используется и в edit) — forward, чтобы add собирал --set. }
function collectSets: TStringDynArray; forward;

function doDaemonsAdd: Integer;
var
  spec: TAddSpec;
begin
  spec.Engine := optionValue('--engine', '');
  spec.ModelName := optionValue('--model', '');
  spec.Host := optionValue('--host', '');
  spec.Language := optionValue('--lang', '');
  spec.Name := optionValue('--name', '');
  spec.Port := StrToIntDef(optionValue('--port', ''), -1);
  Result := runDaemonsAdd(activeConfigPath, activeManifestPath, spec, collectSets, hasFlag('--json'));
end;

{ Имя целевого инстанса для команд remove/edit/…: позиционный аргумент после
  команды (если не начинается с --), иначе --name. }
function targetName: string;
begin
  if (ParamCount >= 3) and (Copy(ParamStr(3), 1, 2) <> '--') then
    Result := ParamStr(3)
  else
    Result := optionValue('--name', '');
end;

function doDaemonsRemove: Integer;
begin
  Result := runDaemonsRemove(activeConfigPath, targetName, hasFlag('--json'));
end;

{ Все значения повторяющегося флага --set key=value. }
function collectSets: TStringDynArray;
var
  i, n: Integer;
begin
  SetLength(Result, 0);
  n := 0;
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = '--set' then
    begin
      SetLength(Result, n + 1);
      Result[n] := ParamStr(i + 1);
      Inc(n);
    end;
end;

function doDaemonsEdit: Integer;
begin
  Result := runDaemonsEdit(activeConfigPath, targetName,
    optionValue('--model', ''), StrToIntDef(optionValue('--port', ''), -1),
    collectSets, hasFlag('--json'));
end;

function dispatchDaemons(const aCommand: string): Integer;
begin
  if SameText(aCommand, 'list') then
    Result := doDaemonsList
  else if SameText(aCommand, 'add') then
    Result := doDaemonsAdd
  else if SameText(aCommand, 'remove') then
    Result := doDaemonsRemove
  else if SameText(aCommand, 'edit') then
    Result := doDaemonsEdit
  else if SameText(aCommand, 'start') then
    Result := runDaemonsStart(activeConfigPath, targetName, activeTimeoutMs, hasFlag('--json'))
  else if SameText(aCommand, 'stop') then
    Result := runDaemonsStop(activeConfigPath, targetName, hasFlag('--json'))
  else if SameText(aCommand, 'restart') then
    Result := runDaemonsRestart(activeConfigPath, targetName, activeTimeoutMs, hasFlag('--json'))
  else
  begin
    writeErr('echoctl: unknown daemons command: ' + aCommand);
    Result := EXIT_USAGE;
  end;
end;

function dispatchModels(const aCommand: string): Integer;
begin
  if SameText(aCommand, 'list') then
    Result := runModelsList(activeManifestPath, hasFlag('--json'))
  else if SameText(aCommand, 'download') then
    Result := runModelsDownload(activeManifestPath, targetName, hasFlag('--json'))
  else if SameText(aCommand, 'delete') then
    Result := runModelsDelete(activeManifestPath, activeConfigPath, targetName,
      hasFlag('--dry-run'), hasFlag('--force'), hasFlag('--json'))
  else
  begin
    writeErr('echoctl: unknown models command: ' + aCommand);
    Result := EXIT_USAGE;
  end;
end;

function dispatchConfig(const aCommand: string): Integer;
begin
  if SameText(aCommand, 'get') then
    Result := runConfigGet(activeConfigPath, hasFlag('--json'))
  else if SameText(aCommand, 'set') then
    Result := runConfigSet(activeConfigPath, ParamStr(3), ParamStr(4), hasFlag('--json'))
  else if SameText(aCommand, 'schema') then
    Result := runConfigSchema(hasFlag('--json'))
  else
  begin
    writeErr('echoctl: unknown config command: ' + aCommand);
    Result := EXIT_USAGE;
  end;
end;

function run: Integer;
var
  group: string;
  command: string;
begin
  if ParamCount = 0 then
  begin
    printUsage;
    Exit(EXIT_OK);
  end;

  group := ParamStr(1);

  if SameText(group, 'help') or (group = '-h') or (group = '--help') then
  begin
    printUsage;
    Exit(EXIT_OK);
  end;
  if SameText(group, 'version') or (group = '-v') or (group = '--version') then
  begin
    printVersion;
    Exit(EXIT_OK);
  end;

  if ParamCount >= 2 then
    command := ParamStr(2)
  else
    command := '';

  if SameText(group, 'daemons') then
    Result := dispatchDaemons(command)
  else if SameText(group, 'models') then
    Result := dispatchModels(command)
  else if SameText(group, 'config') then
    Result := dispatchConfig(command)
  else
  begin
    writeErr('echoctl: unknown group: ' + group);
    writeErr('Run "echoctl help" for usage.');
    Result := EXIT_USAGE;
  end;
end;

begin
  { PASCAL_RULES §7: стабильный десятичный разделитель для JSON/числового I/O. }
  DefaultFormatSettings.DecimalSeparator := '.';
  try
    ExitCode := run;
  except
    on E: Exception do
    begin
      writeErr('echoctl: ' + E.ClassName + ': ' + E.Message);
      ExitCode := EXIT_RUNTIME;
    end;
  end;
end.
