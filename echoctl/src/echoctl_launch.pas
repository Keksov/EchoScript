unit echoctl_launch;

{ Запуск/остановка демонов из echoctl.

  Ключевое (DF-D7): демон стартует через `cmd /c ""exe" args > log 2>&1"` с
  CreateProcess(bInheritHandles=FALSE). Редирект делает cmd (открывает лог-файл сам),
  поэтому наследование хендлов echoctl НЕ нужно для логов — и мы ставим
  bInheritHandles=FALSE, из-за чего демон не наследует ни один хендл echoctl (включая
  слушающий сокет :3001, унаследованный от Bun) → давняя утечка сокета устранена.

  Готовность определяется по маркеру "warmup ready" в лог-файле (реальный прогрев,
  а не только открытие порта). }

{$mode objfpc}{$H+}

interface

uses
  Classes;

type
  TWarmupOutcome = (woReady, woFailed, woTimeout);

{ Старт демона детачем. aEnv — пары Name=Value (ставятся в окружение echoctl, наследуются
  cmd→демоном). Возврат False при ошибке CreateProcess (aErr — текст). }
function spawnDaemon(const aExePath, aArgs, aWorkDir, aLogPath: string;
  aEnv: TStringList; out aPid: Integer; out aErr: string): Boolean;

{ Ждёт "warmup ready" в логе (или маркер провала) до таймаута. }
function waitWarmup(const aLogPath: string; aTimeoutMs: Integer; out aDetail: string): TWarmupOutcome;

function isPortOpen(const aHost: string; aPort: Integer): Boolean;
function waitPortOpen(const aHost: string; aPort, aTimeoutMs: Integer): Boolean;
function waitPortClosed(const aHost: string; aPort, aTimeoutMs: Integer): Boolean;

{ Последние N символов лога — для диагностики в сообщении об ошибке. }
function logTail(const aLogPath: string; aMaxChars: Integer): string;

implementation

uses
  SysUtils, Windows, ssockets;

function readFileBestEffort(const aPath: string): string;
var
  fs: TFileStream;
begin
  Result := '';
  try
    fs := TFileStream.Create(aPath, fmOpenRead or fmShareDenyNone);
    try
      if fs.Size > 0 then
      begin
        SetLength(Result, fs.Size);
        fs.ReadBuffer(Result[1], Length(Result));
      end;
    finally
      fs.Free;
    end;
  except
    Result := '';
  end;
end;

function spawnDaemon(const aExePath, aArgs, aWorkDir, aLogPath: string;
  aEnv: TStringList; out aPid: Integer; out aErr: string): Boolean;
var
  si: STARTUPINFOA;
  pi: PROCESS_INFORMATION;
  cmdLine: string;
  i: Integer;
begin
  aPid := 0;
  aErr := '';
  if aEnv <> nil then
    for i := 0 to aEnv.Count - 1 do
      SetEnvironmentVariable(PChar(aEnv.Names[i]), PChar(aEnv.ValueFromIndex[i]));

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  FillChar(pi, SizeOf(pi), 0);

  { Двойные внешние кавычки — робастная форма `cmd /c "..."` (cmd снимает внешнюю пару). }
  cmdLine := 'cmd.exe /c ""' + aExePath + '" ' + aArgs + ' > "' + aLogPath + '" 2>&1"';
  UniqueString(cmdLine);

  Result := CreateProcess(nil, PChar(cmdLine), nil, nil, False { bInheritHandles },
    CREATE_NO_WINDOW, nil, PChar(aWorkDir), si, pi);
  if Result then
  begin
    aPid := pi.dwProcessId;
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end
  else
    aErr := 'CreateProcess failed (win err ' + IntToStr(GetLastError) + ')';
end;

function waitWarmup(const aLogPath: string; aTimeoutMs: Integer; out aDetail: string): TWarmupOutcome;
var
  waited: Integer;
  content: string;
begin
  aDetail := '';
  waited := 0;
  while waited < aTimeoutMs do
  begin
    content := readFileBestEffort(aLogPath);
    if Pos('warmup ready', content) > 0 then
    begin
      aDetail := 'warmup ready';
      Exit(woReady);
    end;
    if (Pos('warmup failed', content) > 0) or (Pos('Fatal:', content) > 0) then
    begin
      aDetail := 'warmup failed';
      Exit(woFailed);
    end;
    Sleep(500);
    Inc(waited, 500);
  end;
  aDetail := 'timeout after ' + IntToStr(aTimeoutMs div 1000) + 's';
  Result := woTimeout;
end;

function isPortOpen(const aHost: string; aPort: Integer): Boolean;
var
  sock: TInetSocket;
begin
  Result := False;
  try
    sock := TInetSocket.Create(aHost, aPort);
    try
      Result := True;
    finally
      sock.Free;
    end;
  except
    on E: ESocketError do
      Result := False;
  end;
end;

function waitPortOpen(const aHost: string; aPort, aTimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while waited < aTimeoutMs do
  begin
    if isPortOpen(aHost, aPort) then
      Exit(True);
    Sleep(300);
    Inc(waited, 300);
  end;
  Result := False;
end;

function waitPortClosed(const aHost: string; aPort, aTimeoutMs: Integer): Boolean;
var
  waited: Integer;
begin
  waited := 0;
  while waited < aTimeoutMs do
  begin
    if not isPortOpen(aHost, aPort) then
      Exit(True);
    Sleep(300);
    Inc(waited, 300);
  end;
  Result := False;
end;

function logTail(const aLogPath: string; aMaxChars: Integer): string;
var
  content: string;
begin
  content := readFileBestEffort(aLogPath);
  if Length(content) > aMaxChars then
    Result := Copy(content, Length(content) - aMaxChars + 1, aMaxChars)
  else
    Result := content;
end;

end.
