program echoctl;

{ echoctl — EchoScript daemon & model fleet control (FPC CLI).

  Единственный движок управления флотом демонов и моделями: CRUD инстансов
  ws_daemons, per-instance настройки, жизненный цикл моделей (download/delete),
  запуск/остановка демонов, правка настроек оркестратора. config.json —
  единственный писатель здесь (atomic temp+rename). UI/Bun — тонкая обёртка,
  вызывающая echoctl <cmd> --json.

  Этот файл (DF0.2) — скелет: разбор аргументов и диспетчер групп/команд с
  заглушками. Реальные команды подключаются по шагам DF0.3+. }

{$mode objfpc}{$H+}

uses
  SysUtils,
  fpjson,
  echoctl_config,
  echoctl_daemons;

const
  ECHOCTL_VERSION = '0.1.0';

  { Коды возврата — стабильный контракт для обёртки и смоков. }
  EXIT_OK       = 0;
  EXIT_RUNTIME  = 1;
  EXIT_USAGE    = 2;
  EXIT_NOTIMPL  = 3;

procedure writeErr(const aMessage: string);
begin
  WriteLn(StdErr, aMessage);
end;

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
  WriteLn('Other:');
  WriteLn('  echoctl version    print version and exit');
  WriteLn('  echoctl help       print this help and exit');
  WriteLn;
  WriteLn('Notes:');
  WriteLn('  --json   emit machine-readable JSON (for the control-panel wrapper)');
end;

{ Заглушка для распознанной, но ещё не реализованной подкоманды. }
function notImplemented(const aGroup, aCommand: string): Integer;
begin
  writeErr(Format('echoctl: "%s %s" is not implemented yet', [aGroup, aCommand]));
  Result := EXIT_NOTIMPL;
end;

function isKnown(const aValue: string; const aOptions: array of string): Boolean;
var
  option: string;
begin
  for option in aOptions do
    if SameText(aValue, option) then
      Exit(True);
  Result := False;
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

{ Загрузка активного config.json (--config override или поиск от exe). Владелец — вызывающий. }
function loadActiveConfig: TJSONObject;
begin
  Result := loadConfigObject(optionValue('--config', resolveDefaultConfigPath));
end;

function doDaemonsList: Integer;
var
  config: TJSONObject;
begin
  config := loadActiveConfig;
  try
    Result := runDaemonsList(config, hasFlag('--json'));
  finally
    config.Free;
  end;
end;

function dispatchDaemons(const aCommand: string): Integer;
begin
  if SameText(aCommand, 'list') then
    Result := doDaemonsList
  else if isKnown(aCommand, ['add', 'remove', 'edit', 'start', 'stop', 'restart']) then
    Result := notImplemented('daemons', aCommand)
  else
  begin
    writeErr('echoctl: unknown daemons command: ' + aCommand);
    Result := EXIT_USAGE;
  end;
end;

function dispatchModels(const aCommand: string): Integer;
begin
  if isKnown(aCommand, ['list', 'download', 'delete']) then
    Result := notImplemented('models', aCommand)
  else
  begin
    writeErr('echoctl: unknown models command: ' + aCommand);
    Result := EXIT_USAGE;
  end;
end;

function dispatchConfig(const aCommand: string): Integer;
begin
  if isKnown(aCommand, ['get', 'set', 'schema']) then
    Result := notImplemented('config', aCommand)
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
  { PASCAL_RULES §7: стабильный десятичный разделитель для будущего JSON/числового I/O. }
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
