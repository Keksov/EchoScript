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
  ECHOTAIL_VERSION = '0.1.0';

  EXIT_OK      = 0;
  EXIT_RUNTIME = 1;
  EXIT_USAGE   = 2;

  TAIL_CHUNK   = 65536;
  BURST_CAP    = 1048576;
  POLL_MS      = 250;

  ENABLE_VT    = 4; { ENABLE_VIRTUAL_TERMINAL_PROCESSING }

  C_RED   = #27'[31m';
  C_GREEN = #27'[32m';
  C_RESET = #27'[0m';

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
  WriteLn('  echotail <logpath> [--tail N] [--title T] [--no-color]');
  WriteLn;
  WriteLn('  <logpath>     log file to follow (waits for it to appear)');
  WriteLn('  --tail N      show the last N lines first (default 50)');
  WriteLn('  --title T     set the console/tab title');
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
    if (ParamStr(i) = '--tail') or (ParamStr(i) = '--title') then
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

procedure followLog(const aPath: string; aTailN: Integer);
var
  pos, size, readLen, startPos: Int64;
  h: THandle;
  waiting: Boolean;
  s: RawByteString;
begin
  pos := -1;
  waiting := False;
  while True do
  begin
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
  tailN: Integer;
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
  title := optionValue('--title', '');
  if title <> '' then
    SetConsoleTitle(PChar(title));

  setupColor;
  followLog(logPath, tailN);
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
