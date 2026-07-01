unit monitor_control;

{ Управление демонами: start/stop/restart через существующие скрипты демонов.
  Запуск скрипта инкапсулирован в TScriptRunner (инъектируется для тестов). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  monitor_core;

const
  CONTROL_OK               = 0;
  CONTROL_ERR_NO_SCRIPT     = -1;   { скрипт не задан в инвентаре }
  CONTROL_ERR_SCRIPT_MISSING = -2;  { файл скрипта не найден на диске }

type
  { Абстракция запуска скрипта. Реальная — TProcess; в тестах — фейковая. }
  TScriptRunner = class
  public
    function    runScript(const aScriptPath: string): Integer; virtual; abstract;
  end;

  { Реальный раннер: cmd.exe /c <script>, ждёт завершения. }
  TRealScriptRunner = class(TScriptRunner)
  public
    function    runScript(const aScriptPath: string): Integer; override;
  end;

function    resolveScriptPath(const aProjectRoot, aRelScript: string): string;
function    startDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;
function    stopDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;
function    restartDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;

implementation

uses
  process;

function TRealScriptRunner.runScript(const aScriptPath: string): Integer;
var
  proc: TProcess;
begin
  proc := TProcess.Create(nil);
  try
    proc.Executable := 'cmd.exe';
    proc.Parameters.Add('/c');
    proc.Parameters.Add(aScriptPath);
    proc.Options := [poWaitOnExit];
    proc.Execute;
    Result := proc.ExitStatus;
  finally
    proc.Free;
  end;
end;

function resolveScriptPath(const aProjectRoot, aRelScript: string): string;
var
  rel: string;
begin
  rel := StringReplace(Trim(aRelScript), '/', PathDelim, [rfReplaceAll]);
  Result := ExpandFileName(IncludeTrailingPathDelimiter(aProjectRoot) + rel);
end;

function runConfiguredScript(
  const aProjectRoot: string;
  const aRelScript: string;
  aRunner: TScriptRunner
): Integer;
var
  scriptPath: string;
begin
  if Trim(aRelScript) = '' then
    Exit(CONTROL_ERR_NO_SCRIPT);

  scriptPath := resolveScriptPath(aProjectRoot, aRelScript);
  if not FileExists(scriptPath) then
    Exit(CONTROL_ERR_SCRIPT_MISSING);

  if aRunner = nil then
    raise Exception.Create('script runner is nil');

  Result := aRunner.runScript(scriptPath);
end;

function startDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;
begin
  Result := runConfiguredScript(aProjectRoot, aItem.StartScript, aRunner);
end;

function stopDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;
begin
  Result := runConfiguredScript(aProjectRoot, aItem.StopScript, aRunner);
end;

function restartDaemon(const aItem: TDaemonInventoryItem; const aProjectRoot: string; aRunner: TScriptRunner): Integer;
begin
  { stop игнорируем по коду (демон мог быть не запущен), затем start. }
  stopDaemon(aItem, aProjectRoot, aRunner);
  Result := startDaemon(aItem, aProjectRoot, aRunner);
end;

end.
