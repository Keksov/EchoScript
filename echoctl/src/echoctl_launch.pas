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

{ Убить процесс, слушающий TCP-порт aPort (Win-API, без PowerShell). True = порт свободен. }
function stopListenerOnPort(aPort: Integer): Boolean;

{ Dev-режим (ECHOSCRIPT_DEV=1) + наличие wt.exe — открывать echotail-вкладку на лог. }
function devTailEnabled: Boolean;

{ Открыть WT-вкладку с echotail на лог демона (dev). Best-effort, тихо пропускает,
  если нет wt.exe/echotail.exe. Демон остаётся без окна — это лишь просмотрщик лога.
  aPort > 0 → echotail следит за портом (--watch-port): маркеры stopped/listening. }
procedure openLogTab(const aRepoRoot, aTitle, aLogPath: string; aPort: Integer);

{ Вкладки доступны: есть wt.exe и собран echotail.exe (для честной диагностики daemons tabs). }
function canOpenLogTabs(const aRepoRoot: string): Boolean;

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

const
  AF_INET_ = 2;
  TCP_TABLE_OWNER_PID_LISTENER = 3;
  MIB_TCP_STATE_LISTEN = 2;

type
  TMibTcpRowOwnerPid = record
    dwState: DWORD;
    dwLocalAddr: DWORD;
    dwLocalPort: DWORD;
    dwRemoteAddr: DWORD;
    dwRemotePort: DWORD;
    dwOwningPid: DWORD;
  end;
  PMibTcpRowOwnerPid = ^TMibTcpRowOwnerPid;

function GetExtendedTcpTable(pTcpTable: Pointer; var pdwSize: DWORD; bOrder: BOOL;
  ulAf: ULONG; TableClass: DWORD; Reserved: DWORD): DWORD; stdcall;
  external 'iphlpapi.dll' name 'GetExtendedTcpTable';

{ PID процесса, слушающего TCP-порт aPort (IPv4); 0, если нет. }
function pidListeningOnPort(aPort: Integer): DWORD;
var
  size, numEntries, i: DWORD;
  buf: Pointer;
  row: PMibTcpRowOwnerPid;
  localPort: Integer;
begin
  Result := 0;
  size := 0;
  GetExtendedTcpTable(nil, size, False, AF_INET_, TCP_TABLE_OWNER_PID_LISTENER, 0);
  if size = 0 then
    Exit;
  buf := GetMem(size);
  try
    if GetExtendedTcpTable(buf, size, False, AF_INET_, TCP_TABLE_OWNER_PID_LISTENER, 0) <> 0 then
      Exit;
    numEntries := PDWORD(buf)^;                              { dwNumEntries }
    row := PMibTcpRowOwnerPid(PByte(buf) + SizeOf(DWORD));   { первая строка после счётчика }
    i := 0;
    while i < numEntries do
    begin
      { dwLocalPort — network byte order в младших 2 байтах }
      localPort := ((row^.dwLocalPort and $FF) shl 8) or ((row^.dwLocalPort shr 8) and $FF);
      if (row^.dwState = MIB_TCP_STATE_LISTEN) and (localPort = aPort) then
        Exit(row^.dwOwningPid);
      Inc(row);
      Inc(i);
    end;
  finally
    FreeMem(buf);
  end;
end;

function stopListenerOnPort(aPort: Integer): Boolean;
var
  pid: DWORD;
  h: THandle;
begin
  pid := pidListeningOnPort(aPort);
  if pid = 0 then
    Exit(True);   { никто не слушает — считаем остановленным }
  h := OpenProcess(PROCESS_TERMINATE, False, pid);
  if h = 0 then
    Exit(False);
  try
    Result := TerminateProcess(h, 1);
  finally
    CloseHandle(h);
  end;
end;

{ Путь к wt.exe (Windows Terminal) в WindowsApps, или '' если нет. }
function wtExePath: string;
var
  la: string;
begin
  la := SysUtils.GetEnvironmentVariable('LOCALAPPDATA');
  if la = '' then
    Exit('');
  Result := IncludeTrailingPathDelimiter(la) + 'Microsoft\WindowsApps\wt.exe';
  if not FileExists(Result) then
    Result := '';
end;

function devTailEnabled: Boolean;
begin
  Result := (SysUtils.GetEnvironmentVariable('ECHOSCRIPT_DEV') = '1') and (wtExePath <> '');
end;

function canOpenLogTabs(const aRepoRoot: string): Boolean;
begin
  Result := (wtExePath <> '') and FileExists(IncludeTrailingPathDelimiter(aRepoRoot) +
    'echotail' + PathDelim + 'build' + PathDelim + 'x64' + PathDelim + 'echotail.exe');
end;

procedure openLogTab(const aRepoRoot, aTitle, aLogPath: string; aPort: Integer);
var
  wt, echotailExe, watch, cmdLine: string;
  si: STARTUPINFOA;
  pi: PROCESS_INFORMATION;
begin
  wt := wtExePath;
  if wt = '' then
    Exit;
  echotailExe := IncludeTrailingPathDelimiter(aRepoRoot) +
    'echotail' + PathDelim + 'build' + PathDelim + 'x64' + PathDelim + 'echotail.exe';
  if not FileExists(echotailExe) then
    Exit; { не собран → тихо пропускаем, старт демона не ломаем }

  watch := '';
  if aPort > 0 then
    watch := ' --watch-port ' + IntToStr(aPort);

  { Запуск wt через cmd /c: прямой CreateProcess у app-execution-alias wt.exe окно не создаёт
    (алиас резолвится оболочкой). Двойные внешние кавычки — cmd снимает внешнюю пару (как в
    spawnDaemon). Итог для cmd: "<wt>" -w 0 new-tab --title "<t> log" "<echotail>" "<log>" --tail 200. }
  cmdLine := 'cmd.exe /c ""' + wt + '" -w 0 new-tab --title "' + aTitle + ' log" "' +
    echotailExe + '" "' + aLogPath + '" --tail 200 --title "' + aTitle + ' log"' + watch + '"';
  UniqueString(cmdLine);

  FillChar(si, SizeOf(si), 0);
  si.cb := SizeOf(si);
  FillChar(pi, SizeOf(pi), 0);
  if CreateProcess(nil, PChar(cmdLine), nil, nil, False, CREATE_NO_WINDOW, nil,
      PChar(aRepoRoot), si, pi) then
  begin
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
  end;
end;

end.
