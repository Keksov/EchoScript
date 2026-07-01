program test_monitor_core;

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils,
  monitor_core;

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

function resolveInventoryPath: string;
begin
  if ParamCount >= 1 then
    Exit(ParamStr(1));
  { exe at orchestrator/monitor/build/x64 -> up 2 = orchestrator/monitor }
  Result := ExpandFileName(
    IncludeTrailingPathDelimiter(ExtractFileDir(ParamStr(0))) + '..' + PathDelim + '..' + PathDelim + 'daemons.json'
  );
end;

var
  inv: TDaemonInventory;
  item: TDaemonInventoryItem;
  invPath: string;

begin
  invPath := resolveInventoryPath;
  WriteLn('inventory: ', invPath);
  inv := loadDaemonInventory(invPath);

  Ok('inventory has 6 daemons', Length(inv) = 6);
  Ok('vosk_ru present port 7701', findDaemon(inv, 'vosk_ru', item) and (item.Port = 7701));
  Ok('vosk_ru_cmd present port 7702', findDaemon(inv, 'vosk_ru_cmd', item) and (item.Port = 7702));
  Ok('whisperdaemon present port 7801', findDaemon(inv, 'whisperdaemon', item) and (item.Port = 7801));
  Ok('vibevoice present port 7802 kind python', findDaemon(inv, 'vibevoice', item) and (item.Port = 7802) and (item.Kind = 'python'));
  Ok('diarization present port 7900 kind sherpa', findDaemon(inv, 'diarization', item) and (item.Port = 7900) and (item.Kind = 'sherpa'));
  Ok('orchestrator present port 3000 kind node health http',
    findDaemon(inv, 'orchestrator', item) and (item.Port = 3000) and (item.Kind = 'node') and (item.HealthKind = 'http'));
  Ok('unknown daemon not found', not findDaemon(inv, 'does_not_exist', item));
  Ok('start/stop scripts populated', findDaemon(inv, 'diarization', item) and (item.StartScript <> '') and (item.StopScript <> ''));
  Ok('ws_resource defaults to /', findDaemon(inv, 'vosk_ru', item) and (item.WsResource = '/'));
  Ok('health kind ws', findDaemon(inv, 'whisperdaemon', item) and (item.HealthKind = 'ws'));

  WriteLn('summary: pass=', gPass, ' fail=', gFail);
  if gFail > 0 then
    Halt(1);
end.
