program monitor;

{ CLI управления и мониторинга демонами распознавания.
  Поверх UI-независимого ядра (monitor_core/status/control). }

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils,
  fpjson,
  monitor_core,
  monitor_status,
  monitor_control;

function exeDir: string;
begin
  Result := ExtractFileDir(ExpandFileName(ParamStr(0)));
end;

{ exe: orchestrator/monitor/build/x64/monitor.exe -> inventory на 2 уровня выше }
function resolveInventoryPath: string;
begin
  Result := ExpandFileName(
    IncludeTrailingPathDelimiter(exeDir) + '..' + PathDelim + '..' + PathDelim + 'daemons.json'
  );
end;

{ project root: exe на 4 уровня ниже корня (build/x64 -> monitor -> orchestrator -> root) }
function resolveProjectRoot: string;
var
  idx: Integer;
begin
  Result := exeDir;
  for idx := 1 to 4 do
    Result := ExtractFileDir(Result);
end;

function hasFlag(const aName: string): Boolean;
var
  idx: Integer;
begin
  Result := False;
  for idx := 1 to ParamCount do
    if SameText(ParamStr(idx), aName) then
      Exit(True);
end;

{ первый позиционный аргумент (не начинающийся с '-') начиная с индекса aFrom }
function positionalArg(aFrom: Integer): string;
var
  idx: Integer;
  arg: string;
begin
  Result := '';
  for idx := aFrom to ParamCount do
  begin
    arg := ParamStr(idx);
    if (arg <> '') and (arg[1] <> '-') then
      Exit(arg);
  end;
end;

procedure printUsage;
begin
  WriteLn('Usage: monitor <command> [args]');
  WriteLn('  list                        список демонов из daemons.json');
  WriteLn('  status [<name>] [--json]    статус всех или одного демона');
  WriteLn('  start <name>                запустить демон (start-скрипт)');
  WriteLn('  stop <name>                 остановить демон (stop-скрипт)');
  WriteLn('  restart <name>              перезапустить (stop -> start)');
  WriteLn('  -h, --help                  показать справку');
end;

procedure cmdList(const aInv: TDaemonInventory);
var
  idx: Integer;
  it: TDaemonInventoryItem;
begin
  WriteLn(Format('%-18s %-8s %-22s %s', ['NAME', 'KIND', 'ENDPOINT', 'MODEL']));
  for idx := 0 to High(aInv) do
  begin
    it := aInv[idx];
    WriteLn(Format('%-18s %-8s %-22s %s',
      [it.Name, it.Kind, it.Host + ':' + IntToStr(it.Port), it.ModelName]));
  end;
end;

function statusToJson(const aStatuses: TDaemonStatuses): string;
var
  idx: Integer;
  arr: TJSONArray;
  obj: TJSONObject;
begin
  arr := TJSONArray.Create;
  try
    for idx := 0 to High(aStatuses) do
    begin
      obj := TJSONObject.Create;
      obj.Add('name', aStatuses[idx].Name);
      obj.Add('host', aStatuses[idx].Host);
      obj.Add('port', aStatuses[idx].Port);
      obj.Add('port_open', aStatuses[idx].PortOpen);
      obj.Add('pid', aStatuses[idx].Pid);
      obj.Add('reachable', aStatuses[idx].Reachable);
      obj.Add('state', aStatuses[idx].HealthState);
      obj.Add('model', aStatuses[idx].ModelName);
      if aStatuses[idx].ErrorText <> '' then
        obj.Add('error', aStatuses[idx].ErrorText);
      arr.Add(obj);
    end;
    Result := arr.FormatJSON;
  finally
    arr.Free;
  end;
end;

procedure printStatusTable(const aStatuses: TDaemonStatuses);
var
  idx: Integer;
  s: TDaemonStatus;
begin
  WriteLn(Format('%-18s %-9s %-7s %-8s %-10s %s', ['NAME', 'STATE', 'PORT', 'PID', 'REACHABLE', 'MODEL']));
  for idx := 0 to High(aStatuses) do
  begin
    s := aStatuses[idx];
    WriteLn(Format('%-18s %-9s %-7s %-8s %-10s %s',
      [s.Name, s.HealthState, IntToStr(s.Port), IntToStr(s.Pid), BoolToStr(s.Reachable, 'yes', 'no'), s.ModelName]));
  end;
end;

function cmdStatus(const aInv: TDaemonInventory; const aName: string; aJson: Boolean): Integer;
var
  statuses: TDaemonStatuses;
  it: TDaemonInventoryItem;
begin
  Result := 0;
  if aName <> '' then
  begin
    if not findDaemon(aInv, aName, it) then
    begin
      WriteLn(StdErr, 'Unknown daemon: ', aName);
      Exit(2);
    end;
    SetLength(statuses, 1);
    statuses[0] := queryDaemonStatus(it, 2000);
  end
  else
    statuses := queryInventoryStatuses(aInv, 2000);

  if aJson then
    WriteLn(statusToJson(statuses))
  else
    printStatusTable(statuses);
end;

function cmdControl(const aInv: TDaemonInventory; const aAction, aName, aRoot: string): Integer;
var
  it: TDaemonInventoryItem;
  runner: TRealScriptRunner;
  rc: Integer;
begin
  if aName = '' then
  begin
    WriteLn(StdErr, aAction, ' requires a daemon name');
    Exit(2);
  end;
  if not findDaemon(aInv, aName, it) then
  begin
    WriteLn(StdErr, 'Unknown daemon: ', aName);
    Exit(2);
  end;

  runner := TRealScriptRunner.Create;
  try
    if SameText(aAction, 'start') then
      rc := startDaemon(it, aRoot, runner)
    else if SameText(aAction, 'stop') then
      rc := stopDaemon(it, aRoot, runner)
    else
      rc := restartDaemon(it, aRoot, runner);
  finally
    runner.Free;
  end;

  if rc = CONTROL_ERR_NO_SCRIPT then
  begin
    WriteLn(StdErr, aName, ': no ', aAction, ' script configured');
    Exit(1);
  end;
  if rc = CONTROL_ERR_SCRIPT_MISSING then
  begin
    WriteLn(StdErr, aName, ': ', aAction, ' script file not found');
    Exit(1);
  end;

  WriteLn(aAction, ' ', aName, ' -> exit ', rc);
  Result := rc;
end;

var
  command: string;
  inv: TDaemonInventory;
  invPath: string;

begin
  command := LowerCase(Trim(ParamStr(1)));

  if (command = '') or (command = 'help') or (command = '-h') or (command = '--help') then
  begin
    printUsage;
    Halt(0);
  end;

  invPath := resolveInventoryPath;
  try
    inv := loadDaemonInventory(invPath);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'Failed to load inventory (', invPath, '): ', E.Message);
      Halt(3);
    end;
  end;

  try
    if command = 'list' then
    begin
      cmdList(inv);
      Halt(0);
    end
    else if command = 'status' then
      Halt(cmdStatus(inv, positionalArg(2), hasFlag('--json')))
    else if (command = 'start') or (command = 'stop') or (command = 'restart') then
      Halt(cmdControl(inv, command, positionalArg(2), resolveProjectRoot))
    else
    begin
      WriteLn(StdErr, 'Unknown command: ', command);
      printUsage;
      Halt(2);
    end;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'Error: ', E.Message);
      Halt(1);
    end;
  end;
end.
