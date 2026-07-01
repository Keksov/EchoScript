unit main_form;

{$mode objfpc}{$H+}

{ GUI-оболочка монитора. WS-часть (fpwebsocket) отсутствует в FPC Lazarus, поэтому
  и статусы, и управление идут через CLI (monitor.exe, собран VendorsCore FPC).
  GUI — тонкий фронт над CLI: таблица статусов (Pixie) + управление (LCL-контролы). }

interface

uses
  Classes,
  SysUtils,
  Process,
  fpjson,
  jsonparser,
  Forms,
  Controls,
  Graphics,
  Dialogs,
  ExtCtrls,
  StdCtrls,
  Pixie.HtmlView;

type
  TGuiStatus = record
    Name        : string;
    Endpoint    : string;
    State       : string;
    Pid         : Integer;
    Reachable   : Boolean;
    Model       : string;
  end;
  TGuiStatuses = array of TGuiStatus;

  TMonitorForm = class(TForm)
    procedure FormCreate({%H-}Sender: TObject);
  private
    FhtmlView       : TPixieHtmlView;
    FtopPanel       : TPanel;
    FtitleLabel     : TLabel;
    FdaemonLabel    : TLabel;
    FdaemonBox      : TComboBox;
    FstartButton    : TButton;
    FstopButton     : TButton;
    FrestartButton  : TButton;
    FrefreshButton  : TButton;
    Ftimer          : TTimer;
    FmonitorExe     : string;
    Fbusy           : Boolean;
    procedure   buildUi;
    procedure   doRefresh({%H-}Sender: TObject);
    procedure   onStart({%H-}Sender: TObject);
    procedure   onStop({%H-}Sender: TObject);
    procedure   onRestart({%H-}Sender: TObject);
    procedure   controlAction(const aAction: string);
    procedure   setBusy(aBusy: Boolean);
    function    resolveMonitorExe: string;
    function    runMonitor(const aArgs: array of string; out aOutput: string): Boolean;
    function    parseStatuses(const aJson: string; out aStatuses: TGuiStatuses): Boolean;
    procedure   populateDaemonBox(const aStatuses: TGuiStatuses);
    procedure   renderStatuses(const aStatuses: TGuiStatuses);
    procedure   renderError(const aMessage: string);
  end;

var
  MonitorForm: TMonitorForm;

implementation

{$R *.lfm}

function htmlEscape(const aValue: string): string;
begin
  Result := StringReplace(aValue, '&', '&amp;', [rfReplaceAll]);
  Result := StringReplace(Result, '<', '&lt;', [rfReplaceAll]);
  Result := StringReplace(Result, '>', '&gt;', [rfReplaceAll]);
  Result := StringReplace(Result, '"', '&quot;', [rfReplaceAll]);
end;

function stateColor(const aState: string): string;
begin
  if (aState = 'ready') or (aState = 'up') then
    Result := '#166534'
  else if (aState = 'loading') or (aState = 'unknown') then
    Result := '#9a3412'
  else if aState = 'failed' then
    Result := '#b91c1c'
  else
    Result := '#6b7280';
end;

function TMonitorForm.resolveMonitorExe: string;
var
  dir: string;
  idx: Integer;
begin
  { GUI exe: orchestrator/monitor/app/build/x64 -> monitor.exe в orchestrator/monitor/build/x64 }
  dir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for idx := 1 to 3 do
    dir := ExtractFileDir(dir);
  Result := IncludeTrailingPathDelimiter(dir) + 'build' + PathDelim + 'x64' + PathDelim + 'monitor.exe';
end;

function TMonitorForm.runMonitor(const aArgs: array of string; out aOutput: string): Boolean;
var
  proc: TProcess;
  buf: array[0..8191] of Byte;
  n: LongInt;
  idx: Integer;
  outStream: TStringStream;
begin
  Result := False;
  aOutput := '';
  if not FileExists(FmonitorExe) then
    Exit(False);

  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  try
    proc.Executable := FmonitorExe;
    for idx := 0 to High(aArgs) do
      proc.Parameters.Add(aArgs[idx]);
    proc.Options := [poUsePipes, poNoConsole];
    proc.Execute;
    repeat
      n := proc.Output.Read(buf, SizeOf(buf));
      if n > 0 then
        outStream.Write(buf, n);
    until n <= 0;
    aOutput := outStream.DataString;
    Result := True;
  finally
    outStream.Free;
    proc.Free;
  end;
end;

function TMonitorForm.parseStatuses(const aJson: string; out aStatuses: TGuiStatuses): Boolean;
var
  data: TJSONData;
  arr: TJSONArray;
  obj: TJSONObject;
  idx: Integer;
begin
  Result := False;
  SetLength(aStatuses, 0);
  data := nil;
  try
    data := GetJSON(aJson);
  except
    on E: Exception do
      Exit(False);
  end;

  try
    if data.JSONType <> jtArray then
      Exit;
    arr := TJSONArray(data);
    SetLength(aStatuses, arr.Count);
    for idx := 0 to arr.Count - 1 do
    begin
      if arr.Items[idx].JSONType <> jtObject then
        Continue;
      obj := TJSONObject(arr.Items[idx]);
      aStatuses[idx].Name := obj.Get('name', '');
      aStatuses[idx].Endpoint := obj.Get('host', '') + ':' + IntToStr(obj.Get('port', 0));
      aStatuses[idx].State := obj.Get('state', '');
      aStatuses[idx].Pid := obj.Get('pid', 0);
      aStatuses[idx].Reachable := obj.Get('reachable', False);
      aStatuses[idx].Model := obj.Get('model', '');
    end;
    Result := True;
  finally
    data.Free;
  end;
end;

procedure TMonitorForm.buildUi;
begin
  FtopPanel := TPanel.Create(Self);
  FtopPanel.Parent := Self;
  FtopPanel.Align := alTop;
  FtopPanel.Height := 88;
  FtopPanel.BevelOuter := bvNone;
  FtopPanel.Color := $00E6DED0;

  FtitleLabel := TLabel.Create(FtopPanel);
  FtitleLabel.Parent := FtopPanel;
  FtitleLabel.Left := 18;
  FtitleLabel.Top := 12;
  FtitleLabel.Caption := 'Daemon Monitor — статус и управление демонами распознавания';

  FdaemonLabel := TLabel.Create(FtopPanel);
  FdaemonLabel.Parent := FtopPanel;
  FdaemonLabel.Left := 18;
  FdaemonLabel.Top := 52;
  FdaemonLabel.Caption := 'Демон:';

  FdaemonBox := TComboBox.Create(FtopPanel);
  FdaemonBox.Parent := FtopPanel;
  FdaemonBox.Left := 72;
  FdaemonBox.Top := 48;
  FdaemonBox.Width := 200;
  FdaemonBox.Style := csDropDownList;

  FstartButton := TButton.Create(FtopPanel);
  FstartButton.Parent := FtopPanel;
  FstartButton.Left := 284;
  FstartButton.Top := 47;
  FstartButton.Width := 78;
  FstartButton.Height := 28;
  FstartButton.Caption := 'Старт';
  FstartButton.OnClick := @onStart;

  FstopButton := TButton.Create(FtopPanel);
  FstopButton.Parent := FtopPanel;
  FstopButton.Left := 368;
  FstopButton.Top := 47;
  FstopButton.Width := 78;
  FstopButton.Height := 28;
  FstopButton.Caption := 'Стоп';
  FstopButton.OnClick := @onStop;

  FrestartButton := TButton.Create(FtopPanel);
  FrestartButton.Parent := FtopPanel;
  FrestartButton.Left := 452;
  FrestartButton.Top := 47;
  FrestartButton.Width := 92;
  FrestartButton.Height := 28;
  FrestartButton.Caption := 'Рестарт';
  FrestartButton.OnClick := @onRestart;

  FrefreshButton := TButton.Create(FtopPanel);
  FrefreshButton.Parent := FtopPanel;
  FrefreshButton.Left := 620;
  FrefreshButton.Top := 47;
  FrefreshButton.Width := 120;
  FrefreshButton.Height := 28;
  FrefreshButton.Anchors := [akTop, akRight];
  FrefreshButton.Caption := 'Обновить';
  FrefreshButton.OnClick := @doRefresh;

  FhtmlView := TPixieHtmlView.Create(Self);
  FhtmlView.Parent := Self;
  FhtmlView.Align := alClient;
  FhtmlView.Color := $00F4F0E8;

  Ftimer := TTimer.Create(Self);
  Ftimer.Interval := 5000;
  Ftimer.OnTimer := @doRefresh;
  Ftimer.Enabled := True;
end;

procedure TMonitorForm.setBusy(aBusy: Boolean);
begin
  Fbusy := aBusy;
  FstartButton.Enabled := not aBusy;
  FstopButton.Enabled := not aBusy;
  FrestartButton.Enabled := not aBusy;
  FrefreshButton.Enabled := not aBusy;
  if aBusy then
    Screen.Cursor := crHourGlass
  else
    Screen.Cursor := crDefault;
end;

procedure TMonitorForm.renderError(const aMessage: string);
var
  html: TStringList;
begin
  html := TStringList.Create;
  try
    html.Add('<!doctype html><html><head><style>');
    html.Add('body{margin:0;padding:28px;background:#f4f0e8;color:#7f1d1d;font-family:"Segoe UI";}');
    html.Add('</style></head><body>');
    html.Add('<h2>Ошибка</h2><p>' + htmlEscape(aMessage) + '</p>');
    html.Add('<p style="color:#6b7280">Ожидается CLI: ' + htmlEscape(FmonitorExe) + '</p>');
    html.Add('</body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

procedure TMonitorForm.populateDaemonBox(const aStatuses: TGuiStatuses);
var
  idx: Integer;
begin
  if FdaemonBox.Items.Count > 0 then
    Exit;
  for idx := 0 to High(aStatuses) do
    FdaemonBox.Items.Add(aStatuses[idx].Name);
  if FdaemonBox.Items.Count > 0 then
    FdaemonBox.ItemIndex := 0;
end;

procedure TMonitorForm.renderStatuses(const aStatuses: TGuiStatuses);
var
  idx: Integer;
  s: TGuiStatus;
  html: TStringList;
begin
  html := TStringList.Create;
  try
    html.Add('<!doctype html><html><head><style>');
    html.Add('body{margin:0;padding:24px;background:#f4f0e8;color:#1c1917;font-family:"Segoe UI";}');
    html.Add('h1{margin:0 0 14px 0;font-size:22px;}');
    html.Add('table{width:100%;border-collapse:collapse;background:#fffdf8;border:1px solid #d6cfc0;border-radius:12px;overflow:hidden;}');
    html.Add('th,td{padding:10px 14px;text-align:left;border-bottom:1px solid #eee5d6;font-size:14px;}');
    html.Add('th{background:#eee5d6;font-weight:600;}');
    html.Add('.dot{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:8px;vertical-align:middle;}');
    html.Add('.muted{color:#6b7280;}');
    html.Add('</style></head><body>');
    html.Add('<h1>Демоны распознавания</h1>');
    html.Add('<table><tr><th>Демон</th><th>Статус</th><th>Endpoint</th><th>PID</th><th>Reachable</th><th>Модель</th></tr>');
    for idx := 0 to High(aStatuses) do
    begin
      s := aStatuses[idx];
      html.Add(
        '<tr><td>' + htmlEscape(s.Name) + '</td>' +
        '<td><span class="dot" style="background:' + stateColor(s.State) + '"></span>' +
          '<strong style="color:' + stateColor(s.State) + '">' + htmlEscape(s.State) + '</strong></td>' +
        '<td class="muted">' + htmlEscape(s.Endpoint) + '</td>' +
        '<td class="muted">' + BoolToStr(s.Pid > 0, IntToStr(s.Pid), '—') + '</td>' +
        '<td>' + BoolToStr(s.Reachable, 'да', 'нет') + '</td>' +
        '<td>' + htmlEscape(s.Model) + '</td></tr>'
      );
    end;
    html.Add('</table>');
    html.Add('<p class="muted" style="margin-top:14px;">Автообновление каждые 5 с. Управление — через CLI monitor.</p>');
    html.Add('</body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

procedure TMonitorForm.doRefresh(Sender: TObject);
var
  json: string;
  statuses: TGuiStatuses;
begin
  if Fbusy then
    Exit;
  setBusy(True);
  try
    if not runMonitor(['status', '--json'], json) or (Trim(json) = '') then
    begin
      renderError('Не удалось запустить CLI или пустой ответ.');
      Exit;
    end;
    if not parseStatuses(json, statuses) then
    begin
      renderError('Не удалось разобрать JSON статуса.');
      Exit;
    end;
    populateDaemonBox(statuses);
    renderStatuses(statuses);
  finally
    setBusy(False);
  end;
end;

procedure TMonitorForm.controlAction(const aAction: string);
var
  daemonName: string;
  output: string;
begin
  if Fbusy then
    Exit;
  if FdaemonBox.ItemIndex < 0 then
  begin
    ShowMessage('Выберите демон.');
    Exit;
  end;
  daemonName := FdaemonBox.Items[FdaemonBox.ItemIndex];

  setBusy(True);
  try
    runMonitor([aAction, daemonName], output);
  finally
    setBusy(False);
  end;

  doRefresh(nil);
end;

procedure TMonitorForm.onStart(Sender: TObject);
begin
  controlAction('start');
end;

procedure TMonitorForm.onStop(Sender: TObject);
begin
  controlAction('stop');
end;

procedure TMonitorForm.onRestart(Sender: TObject);
begin
  controlAction('restart');
end;

procedure TMonitorForm.FormCreate(Sender: TObject);
begin
  Caption := 'Daemon Monitor';
  Fbusy := False;
  FmonitorExe := resolveMonitorExe;
  buildUi;
  doRefresh(nil);
end;

end.
