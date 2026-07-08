program echotail;

{ echotail — follow a log file (tail -f) for EchoScript daemons, cheaply.

  A tiny FPC console app used in dev to show a daemon's log live in a Windows Terminal
  tab (the daemon itself stays windowless; this just follows its log file). ~единицы МБ
  вместо ~78 МБ у pwsh Get-Content -Wait.

  DT0.2 — скелет: разбор аргументов + заглушка follow (реальный follow — DT1.1). }

{$mode objfpc}{$H+}

uses
  SysUtils;

const
  ECHOTAIL_VERSION = '0.1.0';

  EXIT_OK      = 0;
  EXIT_RUNTIME = 1;
  EXIT_USAGE   = 2;

procedure writeErr(const aMessage: string);
begin
  WriteLn(StdErr, aMessage);
end;

procedure printUsage;
begin
  WriteLn('echotail ', ECHOTAIL_VERSION, ' — follow a log file (tail -f) for EchoScript daemons');
  WriteLn;
  WriteLn('Usage:');
  WriteLn('  echotail <logpath> [--tail N] [--title T]');
  WriteLn;
  WriteLn('  <logpath>     log file to follow (waits for it to appear)');
  WriteLn('  --tail N      show the last N lines first (default 50)');
  WriteLn('  --title T     set the console/tab title');
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

{ Первый позиционный аргумент (не флаг и не значение --tail/--title). }
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
    writeErr('echotail: <logpath> is required');
    Exit(EXIT_USAGE);
  end;
  tailN := StrToIntDef(optionValue('--tail', '50'), 50);
  title := optionValue('--title', '');

  { DT0.2: follow-логика — DT1.1. Пока подтверждаем разбор аргументов. }
  WriteLn(Format('echotail: would follow "%s" (tail=%d title="%s") — follow logic lands in DT1.1',
    [logPath, tailN, title]));
  Result := EXIT_OK;
end;

begin
  DefaultFormatSettings.DecimalSeparator := '.';
  try
    ExitCode := run;
  except
    on E: Exception do
    begin
      writeErr('echotail: ' + E.ClassName + ': ' + E.Message);
      ExitCode := EXIT_RUNTIME;
    end;
  end;
end.
