program test_monitor_status;

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils,
  monitor_core,
  monitor_status;

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

procedure runLive(const aHost: string; aPort: Integer);
var
  item: TDaemonInventoryItem;
  st: TDaemonStatus;
begin
  item := emptyDaemonInventoryItem;
  item.Name := 'live';
  item.Host := aHost;
  item.Port := aPort;
  item.WsResource := '/';
  item.HealthKind := 'ws';
  st := queryDaemonStatus(item, 3000);
  WriteLn('LIVE ', aHost, ':', aPort,
    ' port_open=', st.PortOpen,
    ' reachable=', st.Reachable,
    ' state=', st.HealthState,
    ' model=', st.ModelName);
end;

var
  state, model, err: string;
  item: TDaemonInventoryItem;
  st: TDaemonStatus;

begin
  if (ParamCount >= 3) and (ParamStr(1) = '--live') then
  begin
    runLive(ParamStr(2), StrToIntDef(ParamStr(3), 0));
    Halt(0);
  end;

  { parseHealthAck — валидный ответ }
  Ok('parse health_ack ready',
    parseHealthAck('{"event":"health_ack","state":"ready","model_name":"whisper_podlodka"}', state, model, err)
    and (state = 'ready') and (model = 'whisper_podlodka'));

  { parseHealthAck — с ошибкой/failed }
  Ok('parse health_ack failed+error',
    parseHealthAck('{"event":"health_ack","state":"failed","model_name":"x","error":"boom"}', state, model, err)
    and (state = 'failed') and (err = 'boom'));

  { не health_ack -> false }
  Ok('non-ack rejected',
    not parseHealthAck('{"event":"describe_ack"}', state, model, err));

  { битый JSON -> false }
  Ok('bad json rejected',
    not parseHealthAck('not json', state, model, err));

  { закрытый порт -> down }
  Ok('closed port is down', not isPortOpen('127.0.0.1', 59999));

  item := emptyDaemonInventoryItem;
  item.Name := 'closed';
  item.Host := '127.0.0.1';
  item.Port := 59999;
  item.HealthKind := 'ws';
  st := queryDaemonStatus(item, 500);
  Ok('closed daemon status down',
    (not st.PortOpen) and (not st.Reachable) and (st.HealthState = 'down'));

  WriteLn('summary: pass=', gPass, ' fail=', gFail);
  if gFail > 0 then
    Halt(1);
end.
