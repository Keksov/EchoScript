program test_monitor_control;

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils,
  Classes,
  monitor_core,
  monitor_control;

type
  TFakeRunner = class(TScriptRunner)
  public
    Calls   : TStringList;
    RetCode : Integer;
    constructor Create;
    destructor  Destroy; override;
    function    runScript(const aScriptPath: string): Integer; override;
  end;

constructor TFakeRunner.Create;
begin
  inherited Create;
  Calls := TStringList.Create;
  RetCode := 0;
end;

destructor TFakeRunner.Destroy;
begin
  Calls.Free;
  inherited Destroy;
end;

function TFakeRunner.runScript(const aScriptPath: string): Integer;
begin
  Calls.Add(aScriptPath);
  Result := RetCode;
end;

var
  gPass: Integer = 0;
  gFail: Integer = 0;

procedure Ok(const aName: string; aCond: Boolean);
begin
  if aCond then
  begin
    Inc(gPass);
    WriteLn('PASS ', aName);
  end
  else
  begin
    Inc(gFail);
    WriteLn('FAIL ', aName);
  end;
end;

function contains(const aHaystack, aNeedle: string): Boolean;
begin
  Result := Pos(LowerCase(aNeedle), LowerCase(aHaystack)) > 0;
end;

function projectRoot: string;
var
  idx: Integer;
begin
  Result := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for idx := 1 to 4 do
    Result := ExtractFileDir(Result);
end;

var
  inv: TDaemonInventory;
  vosk: TDaemonInventoryItem;
  runner: TFakeRunner;
  bad: TDaemonInventoryItem;
  rc: Integer;
  root: string;

begin
  root := projectRoot;
  WriteLn('project root: ', root);
  inv := loadDaemonInventory(IncludeTrailingPathDelimiter(root) + 'orchestrator' + PathDelim + 'monitor' + PathDelim + 'daemons.json');
  if not findDaemon(inv, 'vosk_ru', vosk) then
  begin
    WriteLn('FATAL: vosk_ru not in inventory');
    Halt(1);
  end;

  { start -> вызывает start-скрипт, возвращает код раннера }
  runner := TFakeRunner.Create;
  try
    runner.RetCode := 42;
    rc := startDaemon(vosk, root, runner);
    Ok('start returns runner code', rc = 42);
    Ok('start invoked 1 script', runner.Calls.Count = 1);
    Ok('start script is start_voskdaemon_ru', (runner.Calls.Count = 1) and contains(runner.Calls[0], 'start_voskdaemon_ru.bat'));
  finally
    runner.Free;
  end;

  { stop -> вызывает stop-скрипт }
  runner := TFakeRunner.Create;
  try
    rc := stopDaemon(vosk, root, runner);
    Ok('stop invoked stop script', (runner.Calls.Count = 1) and contains(runner.Calls[0], 'stop_voskdaemon_ru.bat'));
  finally
    runner.Free;
  end;

  { restart -> stop затем start (2 вызова, порядок) }
  runner := TFakeRunner.Create;
  try
    restartDaemon(vosk, root, runner);
    Ok('restart invoked 2 scripts', runner.Calls.Count = 2);
    Ok('restart order stop then start',
      (runner.Calls.Count = 2)
      and contains(runner.Calls[0], 'stop_voskdaemon_ru.bat')
      and contains(runner.Calls[1], 'start_voskdaemon_ru.bat'));
  finally
    runner.Free;
  end;

  { отсутствующий файл скрипта -> ошибка, раннер не вызван }
  runner := TFakeRunner.Create;
  try
    bad := emptyDaemonInventoryItem;
    bad.Name := 'bad';
    bad.StartScript := 'services/nope/does_not_exist.bat';
    rc := startDaemon(bad, root, runner);
    Ok('missing script -> CONTROL_ERR_SCRIPT_MISSING', rc = CONTROL_ERR_SCRIPT_MISSING);
    Ok('missing script -> runner not called', runner.Calls.Count = 0);
  finally
    runner.Free;
  end;

  { пустой скрипт -> CONTROL_ERR_NO_SCRIPT }
  runner := TFakeRunner.Create;
  try
    bad := emptyDaemonInventoryItem;
    bad.Name := 'empty';
    bad.StartScript := '';
    rc := startDaemon(bad, root, runner);
    Ok('empty script -> CONTROL_ERR_NO_SCRIPT', rc = CONTROL_ERR_NO_SCRIPT);
    Ok('empty script -> runner not called', runner.Calls.Count = 0);
  finally
    runner.Free;
  end;

  WriteLn('summary: pass=', gPass, ' fail=', gFail);
  if gFail > 0 then
    Halt(1);
end.
