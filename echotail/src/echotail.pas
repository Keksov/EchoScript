program echotail;

{ echotail — follow a log file (tail -f) for EchoScript daemons, cheaply.

  A tiny FPC console app used in dev to show a daemon's log live in a Windows Terminal
  tab (the daemon itself stays windowless; this just follows its log file). ~единицы МБ
  вместо ~78 МБ у pwsh Get-Content -Wait.

  DT1.1 follow (tail-f, ротация, UTF-8) + DT1.2 подсветка (ready→зелёный, error→красный),
  с буферизацией неполных строк; цвет авто-выкл при редиректе в файл (или --no-color). }

{$mode objfpc}{$H+}

uses
  SysUtils, Windows;

const
  ECHOTAIL_VERSION = '0.2.0';

  EXIT_OK      = 0;
  EXIT_RUNTIME = 1;
  EXIT_USAGE   = 2;

  TAIL_CHUNK   = 65536;
  BURST_CAP    = 1048576;
  POLL_MS      = 250;

  WATCH_INTERVAL_MS = 2000;         { период проверки --watch-port }
  AF_INET_ = 2;                     { для GetExtendedTcpTable }
  TCP_TABLE_OWNER_PID_LISTENER = 3;
  MIB_TCP_STATE_LISTEN = 2;

  ENABLE_VT    = 4; { ENABLE_VIRTUAL_TERMINAL_PROCESSING }

  C_RED   = #27'[31m';
  C_GREEN = #27'[32m';
  C_RESET = #27'[0m';

type
  { Строка таблицы GetExtendedTcpTable(TCP_TABLE_OWNER_PID_LISTENER). }
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

var
  gStdOut: THandle;
  gColor: Boolean = False;
  gPending: RawByteString = '';

procedure writeRaw(const aBytes: RawByteString);
begin
  if Length(aBytes) > 0 then
    FileWrite(gStdOut, aBytes[1], Length(aBytes));
end;

procedure writeLineRaw(const aText: RawByteString);
begin
  writeRaw(aText + #13#10);
end;

procedure printUsage;
begin
  WriteLn('echotail ', ECHOTAIL_VERSION, ' — follow a log file (tail -f) for EchoScript daemons');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  echotail <logpath> [--tail N] [--title T] [--watch-port N] [--no-color]');
  WriteLn;
  WriteLn('  <logpath>     log file to follow (waits for it to appear)');
  WriteLn('  --tail N      show the last N lines first (default 50)');
  WriteLn('  --title T     set the console/tab title');
  WriteLn('  --watch-port N  watch the daemon''s TCP port; print a marker when it stops/starts listening');
  WriteLn('  --color       force ANSI colouring (default: on for a console, off if redirected)');
  WriteLn('  --no-color    disable ANSI colouring');
  WriteLn('  --help | --version');
end;

function hasFlag(const aName: string): Boolean;
var
  i: Integer;
begin
  for i := 1 to ParamCount do
    if ParamStr(i) = aName then
      Exit(True);
  Result := False;
end;

function optionValue(const aName, aDefault: string): string;
var
  i: Integer;
begin
  for i := 1 to ParamCount - 1 do
    if ParamStr(i) = aName then
      Exit(ParamStr(i + 1));
  Result := aDefault;
end;

function firstPositional: string;
var
  i: Integer;
begin
  i := 1;
  while i <= ParamCount do
  begin
    if (ParamStr(i) = '--tail') or (ParamStr(i) = '--title') or (ParamStr(i) = '--watch-port') then
    begin
      Inc(i, 2);
      Continue;
    end;
    if Copy(ParamStr(i), 1, 1) = '-' then
    begin
      Inc(i);
      Continue;
    end;
    Exit(ParamStr(i));
  end;
  Result := '';
end;

function readRange(aHandle: THandle; aStart, aLen: Int64): RawByteString;
begin
  SetLength(Result, aLen);
  if aLen > 0 then
  begin
    FileSeek(aHandle, aStart, fsFromBeginning);
    FileRead(aHandle, Result[1], aLen);
  end;
end;

function lastNLinesStart(const s: RawByteString; aN: Integer): Integer;
var
  i, count: Integer;
begin
  if aN <= 0 then
    Exit(Length(s) + 1);
  count := 0;
  i := Length(s);
  if (i >= 1) and (s[i] = #10) then
    Dec(i);
  while i >= 1 do
  begin
    if s[i] = #10 then
    begin
      Inc(count);
      if count >= aN then
        Exit(i + 1);
    end;
    Dec(i);
  end;
  Result := 1;
end;

{ Цвет строки по ключевым словам (ASCII-регистронезависимо). '' = без цвета. }
function lineColor(const aContent: RawByteString): RawByteString;
var
  low: RawByteString;
begin
  low := LowerCase(aContent);
  if (Pos('error', low) > 0) or (Pos('fail', low) > 0) or
     (Pos('exception', low) > 0) or (Pos('fatal', low) > 0) then
    Result := C_RED
  else if (Pos('warmup ready', low) > 0) or (Pos('listening', low) > 0) or
          (Pos('ready', low) > 0) or (Pos('started', low) > 0) then
    Result := C_GREEN
  else
    Result := '';
end;

{ Выводит полные строки из aChunk (+ остаток из прошлого раза), подсвечивая. Неполный
  хвост копится в gPending до прихода перевода строки. }
procedure emitColored(const aChunk: RawByteString);
var
  nl, contentLen: Integer;
  line, content, eol, color: RawByteString;
begin
  gPending := gPending + aChunk;
  repeat
    nl := Pos(#10, gPending);
    if nl = 0 then
      Break;
    line := Copy(gPending, 1, nl);   { включая #10 }
    Delete(gPending, 1, nl);

    if not gColor then
    begin
      writeRaw(line);
      Continue;
    end;

    contentLen := Length(line) - 1;  { без #10 }
    if (contentLen >= 1) and (line[contentLen] = #13) then
      Dec(contentLen);               { без #13 }
    content := Copy(line, 1, contentLen);
    eol := Copy(line, contentLen + 1, MaxInt);
    color := lineColor(content);
    if color <> '' then
      writeRaw(color + content + C_RESET + eol)
    else
      writeRaw(line);
  until False;
end;

{ Кто-то слушает TCP-порт aPort (IPv4)? Через GetExtendedTcpTable — БЕЗ подключения к
  порту: connect-проба заставляла бы демона логировать connected/disconnected каждые ~2с,
  замусоривая тот самый лог, который мы показываем. }
function isPortListening(aPort: Integer): Boolean;
var
  size, numEntries, i, ret: DWORD;
  buf: Pointer;
  row: PMibTcpRowOwnerPid;
  localPort, attempt: Integer;
begin
  Result := False;
  { Двухфазный вызов гоночный: таблица может вырасти между запросом размера и чтением
    (ERROR_INSUFFICIENT_BUFFER) — ретраим с запасом, а не трактуем как «не слушает». }
  for attempt := 1 to 3 do
  begin
    size := 0;
    GetExtendedTcpTable(nil, size, False, AF_INET_, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if size = 0 then
      Exit;
    Inc(size, 16 * SizeOf(TMibTcpRowOwnerPid));   { запас на новые сокеты }
    buf := GetMem(size);
    try
      ret := GetExtendedTcpTable(buf, size, False, AF_INET_, TCP_TABLE_OWNER_PID_LISTENER, 0);
      if ret <> 0 then
        Continue;   { не удалось (гонка размера и т.п.) — новая попытка }
      numEntries := PDWORD(buf)^;
      row := PMibTcpRowOwnerPid(PByte(buf) + SizeOf(DWORD));
      i := 0;
      while i < numEntries do
      begin
        { dwLocalPort — network byte order в младших 2 байтах }
        localPort := ((row^.dwLocalPort and $FF) shl 8) or ((row^.dwLocalPort shr 8) and $FF);
        if (row^.dwState = MIB_TCP_STATE_LISTEN) and (localPort = aPort) then
          Exit(True);
        Inc(row);
        Inc(i);
      end;
      Exit(False);  { таблица прочитана, порта нет }
    finally
      FreeMem(buf);
    end;
  end;
end;

{ Служебный маркер echotail (в stdout вкладки, НЕ в лог демона), с цветом если включён. }
procedure writeMarker(const aColor, aText: RawByteString);
begin
  if gColor then
    writeRaw(aColor + aText + C_RESET + #13#10)
  else
    writeLineRaw(aText);
end;

{ Проверка --watch-port раз в WATCH_INTERVAL_MS: переходы open/closed → маркеры.
  aState: -1 unknown / 0 closed / 1 open. Ложного «stopped» из unknown не бывает. }
procedure checkWatchPort(aPort: Integer; var aState: Integer; var aLastTick: QWord);
var
  nowTick: QWord;
  open: Boolean;
begin
  if aPort <= 0 then
    Exit;
  nowTick := GetTickCount64;
  if (aLastTick <> 0) and (nowTick - aLastTick < WATCH_INTERVAL_MS) then
    Exit;
  aLastTick := nowTick;
  open := isPortListening(aPort);
  if open and (aState <> 1) then
  begin
    writeMarker(C_GREEN, '[echotail] daemon listening on port ' + IntToStr(aPort));
    aState := 1;
  end
  else if (not open) and (aState = 1) then
  begin
    writeMarker(C_RED, '[echotail] daemon stopped (port ' + IntToStr(aPort) + ' no longer listening)');
    aState := 0;
  end;
end;

procedure followLog(const aPath: string; aTailN, aWatchPort: Integer);
var
  pos, size, readLen, startPos: Int64;
  h: THandle;
  waiting: Boolean;
  s: RawByteString;
  watchState: Integer;
  watchLast: QWord;
begin
  pos := -1;
  waiting := False;
  watchState := -1;
  watchLast := 0;
  while True do
  begin
    checkWatchPort(aWatchPort, watchState, watchLast);
    if not FileExists(aPath) then
    begin
      if not waiting then
        writeLineRaw('[echotail] waiting for ' + aPath + ' ...');
      waiting := True;
      Sleep(400);
      Continue;
    end;
    waiting := False;

    h := FileOpen(aPath, fmOpenRead or fmShareDenyNone);
    if h = THandle(-1) then
    begin
      Sleep(300);
      Continue;
    end;
    try
      size := FileSeek(h, Int64(0), fsFromEnd);
      if pos = -1 then
      begin
        if size > 0 then
        begin
          readLen := size;
          if readLen > TAIL_CHUNK then
            readLen := TAIL_CHUNK;
          startPos := size - readLen;
          s := readRange(h, startPos, readLen);
          emitColored(Copy(s, lastNLinesStart(s, aTailN), MaxInt));
        end;
        pos := size;
      end
      else if size < pos then
      begin
        writeLineRaw('[echotail] --- log truncated/rotated, re-reading ---');
        pos := 0;
        gPending := '';
      end;

      if size > pos then
      begin
        readLen := size - pos;
        if readLen > BURST_CAP then
          readLen := BURST_CAP;
        emitColored(readRange(h, pos, readLen));
        pos := pos + readLen;
      end;
    finally
      FileClose(h);
    end;
    Sleep(POLL_MS);
  end;
end;

{ Цвет включаем только если stdout — консоль (не файл/пайп) и не задан --no-color. }
procedure setupColor;
var
  mode: DWORD;
begin
  if hasFlag('--no-color') then
    gColor := False
  else if hasFlag('--color') then
    gColor := True   { форс (в т.ч. при редиректе — для тестов) }
  else
    gColor := (GetFileType(gStdOut) = FILE_TYPE_CHAR); { авто: только для консоли }
  if gColor and GetConsoleMode(gStdOut, mode) then
    SetConsoleMode(gStdOut, mode or ENABLE_VT);
end;

function run: Integer;
var
  logPath, title: string;
  tailN, watchPort: Integer;
begin
  if (ParamCount = 0) or hasFlag('--help') or hasFlag('-h') then
  begin
    printUsage;
    Exit(EXIT_OK);
  end;
  if hasFlag('--version') or hasFlag('-v') then
  begin
    WriteLn('echotail ', ECHOTAIL_VERSION);
    Exit(EXIT_OK);
  end;

  logPath := firstPositional;
  if logPath = '' then
  begin
    WriteLn(StdErr, 'echotail: <logpath> is required');
    Exit(EXIT_USAGE);
  end;
  tailN := StrToIntDef(optionValue('--tail', '50'), 50);
  watchPort := StrToIntDef(optionValue('--watch-port', '0'), 0);
  title := optionValue('--title', '');
  if title <> '' then
    SetConsoleTitle(PChar(title));

  setupColor;
  followLog(logPath, tailN, watchPort);
  Result := EXIT_OK;
end;

begin
  gStdOut := GetStdHandle(STD_OUTPUT_HANDLE);
  SetConsoleOutputCP(65001);
  DefaultFormatSettings.DecimalSeparator := '.';
  try
    ExitCode := run;
  except
    on E: Exception do
    begin
      WriteLn(StdErr, 'echotail: ' + E.ClassName + ': ' + E.Message);
      ExitCode := EXIT_RUNTIME;
    end;
  end;
end.
