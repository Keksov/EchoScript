unit monitor_status;

{ Статус демона: проверка порта (TCP) + WS health/describe-клиент.
  UI-независимо. Возвращает TDaemonStatus. }

{$mode objfpc}{$H+}

interface

uses
  SysUtils,
  monitor_core;

type
  TDaemonStatus = record
    Name        : string;
    Host        : string;
    Port        : Integer;
    PortOpen    : Boolean;   { что-то слушает порт (proxy живости процесса-сервера) }
    Pid         : Integer;   { PID процесса-слушателя порта (0 = не найден) }
    Reachable   : Boolean;   { WS подключился и пришёл health_ack }
    HealthState : string;    { down | unknown | up | loading | ready | failed }
    ModelName   : string;
    ErrorText   : string;
  end;

  TDaemonStatuses = array of TDaemonStatus;

{ Чистый парсер health_ack (для юнит-теста, без сокетов). }
function    parseHealthAck(const aJson: string; out aState, aModel, aError: string): Boolean;

function    isPortOpen(const aHost: string; aPort: Integer): Boolean;
function    queryDaemonStatus(const aItem: TDaemonInventoryItem; aWsTimeoutMs: Integer = 2000): TDaemonStatus;
function    queryInventoryStatuses(const aInventory: TDaemonInventory; aWsTimeoutMs: Integer = 2000): TDaemonStatuses;
function    queryDaemonDescribe(const aItem: TDaemonInventoryItem; out aJson: string; aTimeoutMs: Integer = 3000): Boolean;

implementation

uses
  ssockets,
  fpwebsocket,
  fpwebsocketclient,
  fpjson,
  jsonparser,
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  Classes;

function jsonStr(const aObject: TJSONObject; const aName: string): string;
var
  data: TJSONData;
begin
  Result := '';
  if aObject = nil then
    Exit;
  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsString;
end;

function parseHealthAck(const aJson: string; out aState, aModel, aError: string): Boolean;
var
  data: TJSONData;
  root: TJSONObject;
begin
  Result := False;
  aState := '';
  aModel := '';
  aError := '';
  if Trim(aJson) = '' then
    Exit;

  data := nil;
  try
    data := GetJSON(aJson);
  except
    on E: Exception do
      Exit(False);
  end;

  try
    if data.JSONType <> jtObject then
      Exit;
    root := TJSONObject(data);
    if LowerCase(Trim(jsonStr(root, 'event'))) <> 'health_ack' then
      Exit;
    aState := Trim(jsonStr(root, 'state'));
    aModel := Trim(jsonStr(root, 'model_name'));
    aError := Trim(jsonStr(root, 'error'));
    Result := True;
  finally
    data.Free;
  end;
end;

{$ifdef MSWINDOWS}
{ PID процесса, слушающего TCP-порт aPort (через iphlpapi GetExtendedTcpTable).
  Каждый инстанс демона биндит свой порт => это точный PID инстанса. }
function listeningPidOnPort(aPort: Integer): Integer;
type
  TMibTcpRowOwnerPid = record
    dwState      : DWORD;
    dwLocalAddr  : DWORD;
    dwLocalPort  : DWORD;
    dwRemoteAddr : DWORD;
    dwRemotePort : DWORD;
    dwOwningPid  : DWORD;
  end;
  PMibTcpRowOwnerPid = ^TMibTcpRowOwnerPid;
  TGetExtendedTcpTable = function(pTcpTable: Pointer; pdwSize: PDWORD;
    bOrder: LongBool; ulAf: DWORD; TableClass: DWORD; Reserved: DWORD): DWORD; stdcall;
const
  AF_INET_MON = 2;
  TCP_TABLE_OWNER_PID_LISTENER = 3;
var
  hLib: HMODULE;
  getTable: TGetExtendedTcpTable;
  size: DWORD;
  buf: array of Byte;
  numEntries: DWORD;
  idx: DWORD;
  row: PMibTcpRowOwnerPid;
  localPort: Integer;
  rawPort: DWORD;
begin
  Result := 0;
  hLib := LoadLibrary(PChar('iphlpapi.dll'));
  if hLib = 0 then
    Exit;
  try
    Pointer(getTable) := GetProcAddress(hLib, PChar('GetExtendedTcpTable'));
    if not Assigned(getTable) then
      Exit;

    size := 0;
    getTable(nil, @size, False, AF_INET_MON, TCP_TABLE_OWNER_PID_LISTENER, 0);
    if size = 0 then
      Exit;

    SetLength(buf, size);
    if getTable(@buf[0], @size, False, AF_INET_MON, TCP_TABLE_OWNER_PID_LISTENER, 0) <> 0 then
      Exit;

    numEntries := PDWORD(@buf[0])^;
    for idx := 0 to numEntries - 1 do
    begin
      row := PMibTcpRowOwnerPid(@buf[SizeOf(DWORD) + idx * SizeOf(TMibTcpRowOwnerPid)]);
      rawPort := row^.dwLocalPort;
      localPort := ((rawPort and $FF) shl 8) or ((rawPort shr 8) and $FF);
      if localPort = aPort then
        Exit(Integer(row^.dwOwningPid));
    end;
  finally
    FreeLibrary(hLib);
  end;
end;
{$else}
function listeningPidOnPort({%H-}aPort: Integer): Integer;
begin
  Result := 0;
end;
{$endif}

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
    on E: Exception do
      Result := False;
  end;
end;

type
  TWsHealthProbe = class
  private
    FGotAck : Boolean;
    FState  : string;
    FModel  : string;
    FErr    : string;
  public
    procedure   onMessage(Sender: TObject; const aMessage: TWSMessage);
    property    GotAck: Boolean read FGotAck;
    property    State: string read FState;
    property    Model: string read FModel;
    property    Err: string read FErr;
  end;

procedure TWsHealthProbe.onMessage(Sender: TObject; const aMessage: TWSMessage);
var
  ackState, ackModel, ackErr: string;
begin
  if not aMessage.IsText then
    Exit;
  if parseHealthAck(aMessage.AsString, ackState, ackModel, ackErr) then
  begin
    FState := ackState;
    FModel := ackModel;
    FErr := ackErr;
    FGotAck := True;
  end;
end;

function queryWsHealth(
  const aHost: string;
  aPort: Integer;
  const aResource: string;
  aTimeoutMs: Integer;
  out aState, aModel, aError: string
): Boolean;
var
  client: TWebsocketClient;
  probe: TWsHealthProbe;
  endTick: QWord;
  rc: TIncomingResult;
begin
  Result := False;
  aState := '';
  aModel := '';
  aError := '';
  probe := TWsHealthProbe.Create;
  client := TWebsocketClient.Create(nil);
  try
    client.ConnectTimeout := 1500;
    client.CheckTimeout := 50;
    client.HostName := aHost;
    client.Port := aPort;
    if Trim(aResource) <> '' then
      client.Resource := aResource
    else
      client.Resource := '/';
    client.OnMessageReceived := @probe.onMessage;

    try
      client.Connect;
    except
      on E: Exception do
      begin
        aError := E.Message;
        Exit(False);
      end;
    end;

    client.SendMessage('{"event":"health"}');

    endTick := GetTickCount64 + QWord(aTimeoutMs);
    repeat
      rc := client.CheckIncoming;
      if probe.GotAck then
        Break;
      if rc = irClose then
        Break;
      if GetTickCount64 >= endTick then
        Break;
      Sleep(10);
    until False;

    if probe.GotAck then
    begin
      aState := probe.State;
      aModel := probe.Model;
      aError := probe.Err;
      Result := True;
    end;
  finally
    client.Free;
    probe.Free;
  end;
end;

type
  TWsDescribeProbe = class
  private
    FGot  : Boolean;
    FJson : string;
  public
    procedure   onMessage(Sender: TObject; const aMessage: TWSMessage);
    property    Got: Boolean read FGot;
    property    Json: string read FJson;
  end;

procedure TWsDescribeProbe.onMessage(Sender: TObject; const aMessage: TWSMessage);
var
  data: TJSONData;
  root: TJSONObject;
begin
  if not aMessage.IsText then
    Exit;
  data := nil;
  try
    data := GetJSON(aMessage.AsString);
  except
    on E: Exception do
      Exit;
  end;
  try
    if data.JSONType <> jtObject then
      Exit;
    root := TJSONObject(data);
    if LowerCase(Trim(jsonStr(root, 'event'))) = 'describe_ack' then
    begin
      FJson := aMessage.AsString;
      FGot := True;
    end;
  finally
    data.Free;
  end;
end;

function queryDaemonDescribe(const aItem: TDaemonInventoryItem; out aJson: string; aTimeoutMs: Integer = 3000): Boolean;
var
  client: TWebsocketClient;
  probe: TWsDescribeProbe;
  endTick: QWord;
  rc: TIncomingResult;
  resource: string;
begin
  Result := False;
  aJson := '';
  probe := TWsDescribeProbe.Create;
  client := TWebsocketClient.Create(nil);
  try
    client.ConnectTimeout := 1500;
    client.CheckTimeout := 50;
    client.HostName := aItem.Host;
    client.Port := aItem.Port;
    resource := Trim(aItem.WsResource);
    if resource = '' then
      resource := '/';
    client.Resource := resource;
    client.OnMessageReceived := @probe.onMessage;

    try
      client.Connect;
    except
      on E: Exception do
        Exit(False);
    end;

    client.SendMessage('{"event":"describe"}');

    endTick := GetTickCount64 + QWord(aTimeoutMs);
    repeat
      rc := client.CheckIncoming;
      if probe.Got then
        Break;
      if rc = irClose then
        Break;
      if GetTickCount64 >= endTick then
        Break;
      Sleep(10);
    until False;

    if probe.Got then
    begin
      aJson := probe.Json;
      Result := True;
    end;
  finally
    client.Free;
    probe.Free;
  end;
end;

function queryDaemonStatus(const aItem: TDaemonInventoryItem; aWsTimeoutMs: Integer = 2000): TDaemonStatus;
var
  state, model, err: string;
begin
  Result.Name := aItem.Name;
  Result.Host := aItem.Host;
  Result.Port := aItem.Port;
  Result.PortOpen := isPortOpen(aItem.Host, aItem.Port);
  Result.Pid := listeningPidOnPort(aItem.Port);
  Result.Reachable := False;
  Result.HealthState := 'down';
  Result.ModelName := '';
  Result.ErrorText := '';

  if not Result.PortOpen then
    Exit;

  { Порт открыт. }
  if SameText(aItem.HealthKind, 'ws') then
  begin
    if queryWsHealth(aItem.Host, aItem.Port, aItem.WsResource, aWsTimeoutMs, state, model, err) then
    begin
      Result.Reachable := True;
      if state <> '' then
        Result.HealthState := state
      else
        Result.HealthState := 'ready';
      Result.ModelName := model;
      Result.ErrorText := err;
    end
    else
    begin
      { Порт открыт, но WS health не пришёл — считаем «up, health неизвестен». }
      Result.HealthState := 'unknown';
      Result.ErrorText := err;
    end;
  end
  else
  begin
    { health=port/process: открытый порт => up. }
    Result.HealthState := 'up';
    Result.Reachable := True;
  end;
end;

function queryInventoryStatuses(const aInventory: TDaemonInventory; aWsTimeoutMs: Integer = 2000): TDaemonStatuses;
var
  idx: Integer;
begin
  SetLength(Result, Length(aInventory));
  for idx := 0 to High(aInventory) do
    Result[idx] := queryDaemonStatus(aInventory[idx], aWsTimeoutMs);
end;

end.
