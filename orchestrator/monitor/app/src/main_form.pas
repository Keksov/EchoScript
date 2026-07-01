unit main_form;

{$mode objfpc}{$H+}

{ GUI-оболочка монитора. Окно показывается сразу (скелет из daemons.json), при старте
  делается полный опрос (прогрессивно, по одному демону — видно прогрев). Далее —
  режим Manual (кнопка Refresh) по умолчанию, либо Auto-refresh по таймеру (Timeout, сек).
  Health берётся из CLI (fpwebsocket отсутствует в FPC Lazarus); инвентарь — из monitor_core. }

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
  Spin,
  Pixie.HtmlView,
  monitor_core;

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
    FhtmlView         : TPixieHtmlView;
    FtopPanel         : TPanel;
    FtitleLabel       : TLabel;
    FdaemonLabel      : TLabel;
    FdaemonBox        : TComboBox;
    FstartButton      : TButton;
    FstopButton       : TButton;
    FrestartButton    : TButton;
    FrefreshButton    : TButton;
    FautoRefreshCheck : TCheckBox;
    FtimeoutLabel     : TLabel;
    FtimeoutSpin      : TSpinEdit;
    Ftimer            : TTimer;
    FmonitorExe       : string;
    FloadError        : string;
    Finv              : TDaemonInventory;
    Fstatuses         : TGuiStatuses;
    FlastUpdated      : TDateTime;
    Fbusy             : Boolean;
    procedure   buildUi;
    procedure   buildSkeleton;
    procedure   asyncFirstRefresh({%H-}aData: PtrInt);
    procedure   onRefreshClick({%H-}Sender: TObject);
    procedure   onTimer({%H-}Sender: TObject);
    procedure   onAutoRefreshChanged({%H-}Sender: TObject);
    procedure   onTimeoutChanged({%H-}Sender: TObject);
    procedure   applyRefreshMode;
    procedure   initialRefresh;
    procedure   quietRefresh;
    procedure   onStart({%H-}Sender: TObject);
    procedure   onStop({%H-}Sender: TObject);
    procedure   onRestart({%H-}Sender: TObject);
    procedure   controlAction(const aAction: string);
    procedure   setBusy(aBusy: Boolean);
    function    footerNote: string;
    function    resolveMonitorExe: string;
    function    inventoryPath: string;
    function    runMonitor(const aArgs: array of string; out aOutput: string): Boolean;
    function    parseStatuses(const aJson: string; out aStatuses: TGuiStatuses): Boolean;
    procedure   renderStatuses(const aNote: string);
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
  else if (aState = 'loading') or (aState = 'unknown') or (aState = 'проверка…') then
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
  dir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for idx := 1 to 3 do
    dir := ExtractFileDir(dir);
  Result := IncludeTrailingPathDelimiter(dir) + 'build' + PathDelim + 'x64' + PathDelim + 'monitor.exe';
end;

function TMonitorForm.inventoryPath: string;
var
  dir: string;
  idx: Integer;
begin
  dir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for idx := 1 to 3 do
    dir := ExtractFileDir(dir);
  Result := IncludeTrailingPathDelimiter(dir) + 'daemons.json';
end;

function TMonitorForm.runMonitor(const aArgs: array of string; out aOutput: string): Boolean;
var
  proc: TProcess;
  buf: array[0..8191] of Byte;
  n: LongInt;
  avail: LongInt;
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

    { Неблокирующее чтение: пока процесс работает — качаем сообщения (окно отзывчиво). }
    while proc.Running do
    begin
      avail := proc.Output.NumBytesAvailable;
      if avail > 0 then
      begin
        if avail > SizeOf(buf) then
          avail := SizeOf(buf);
        n := proc.Output.Read(buf, avail);
        if n > 0 then
          outStream.Write(buf, n);
      end
      else
      begin
        Application.ProcessMessages;
        Sleep(10);
      end;
    end;

    repeat
      avail := proc.Output.NumBytesAvailable;
      if avail = 0 then
        Break;
      if avail > SizeOf(buf) then
        avail := SizeOf(buf);
      n := proc.Output.Read(buf, avail);
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
  FtopPanel.Height := 120;
  FtopPanel.BevelOuter := bvNone;
  FtopPanel.Color := $00E6DED0;

  FtitleLabel := TLabel.Create(FtopPanel);
  FtitleLabel.Parent := FtopPanel;
  FtitleLabel.Left := 18;
  FtitleLabel.Top := 10;
  FtitleLabel.Caption := 'Daemon Monitor — статус и управление демонами распознавания';

  { Row 2: выбор демона + управление + Refresh }
  FdaemonLabel := TLabel.Create(FtopPanel);
  FdaemonLabel.Parent := FtopPanel;
  FdaemonLabel.Left := 18;
  FdaemonLabel.Top := 46;
  FdaemonLabel.Caption := 'Демон:';

  FdaemonBox := TComboBox.Create(FtopPanel);
  FdaemonBox.Parent := FtopPanel;
  FdaemonBox.Left := 72;
  FdaemonBox.Top := 42;
  FdaemonBox.Width := 190;
  FdaemonBox.Style := csDropDownList;

  FstartButton := TButton.Create(FtopPanel);
  FstartButton.Parent := FtopPanel;
  FstartButton.Left := 272;
  FstartButton.Top := 41;
  FstartButton.Width := 74;
  FstartButton.Height := 28;
  FstartButton.Caption := 'Старт';
  FstartButton.OnClick := @onStart;

  FstopButton := TButton.Create(FtopPanel);
  FstopButton.Parent := FtopPanel;
  FstopButton.Left := 352;
  FstopButton.Top := 41;
  FstopButton.Width := 74;
  FstopButton.Height := 28;
  FstopButton.Caption := 'Стоп';
  FstopButton.OnClick := @onStop;

  FrestartButton := TButton.Create(FtopPanel);
  FrestartButton.Parent := FtopPanel;
  FrestartButton.Left := 432;
  FrestartButton.Top := 41;
  FrestartButton.Width := 88;
  FrestartButton.Height := 28;
  FrestartButton.Caption := 'Рестарт';
  FrestartButton.OnClick := @onRestart;

  FrefreshButton := TButton.Create(FtopPanel);
  FrefreshButton.Parent := FtopPanel;
  FrefreshButton.Left := 620;
  FrefreshButton.Top := 41;
  FrefreshButton.Width := 120;
  FrefreshButton.Height := 28;
  FrefreshButton.Anchors := [akTop, akRight];
  FrefreshButton.Caption := 'Refresh';
  FrefreshButton.OnClick := @onRefreshClick;

  { Row 3: режим обновления }
  FautoRefreshCheck := TCheckBox.Create(FtopPanel);
  FautoRefreshCheck.Parent := FtopPanel;
  FautoRefreshCheck.Left := 18;
  FautoRefreshCheck.Top := 84;
  FautoRefreshCheck.Width := 140;
  FautoRefreshCheck.Caption := 'Auto-refresh';
  FautoRefreshCheck.Checked := False;   { Manual по умолчанию }
  FautoRefreshCheck.OnChange := @onAutoRefreshChanged;

  FtimeoutLabel := TLabel.Create(FtopPanel);
  FtimeoutLabel.Parent := FtopPanel;
  FtimeoutLabel.Left := 168;
  FtimeoutLabel.Top := 86;
  FtimeoutLabel.Caption := 'Timeout, сек:';

  FtimeoutSpin := TSpinEdit.Create(FtopPanel);
  FtimeoutSpin.Parent := FtopPanel;
  FtimeoutSpin.Left := 262;
  FtimeoutSpin.Top := 82;
  FtimeoutSpin.Width := 70;
  FtimeoutSpin.MinValue := 1;
  FtimeoutSpin.MaxValue := 3600;
  FtimeoutSpin.Value := 5;
  FtimeoutSpin.OnChange := @onTimeoutChanged;

  FhtmlView := TPixieHtmlView.Create(Self);
  FhtmlView.Parent := Self;
  FhtmlView.Align := alClient;
  FhtmlView.Color := $00F4F0E8;

  Ftimer := TTimer.Create(Self);
  Ftimer.Interval := 5000;
  Ftimer.OnTimer := @onTimer;
  Ftimer.Enabled := False;   { включается только в режиме Auto-refresh }
end;

procedure TMonitorForm.buildSkeleton;
var
  idx: Integer;
begin
  Finv := loadDaemonInventory(inventoryPath);
  SetLength(Fstatuses, Length(Finv));
  FdaemonBox.Items.BeginUpdate;
  try
    FdaemonBox.Items.Clear;
    for idx := 0 to High(Finv) do
    begin
      Fstatuses[idx].Name := Finv[idx].Name;
      Fstatuses[idx].Endpoint := Finv[idx].Host + ':' + IntToStr(Finv[idx].Port);
      Fstatuses[idx].State := 'ожидание';
      Fstatuses[idx].Pid := 0;
      Fstatuses[idx].Reachable := False;
      Fstatuses[idx].Model := '';
      FdaemonBox.Items.Add(Finv[idx].Name);
    end;
  finally
    FdaemonBox.Items.EndUpdate;
  end;
  if FdaemonBox.Items.Count > 0 then
    FdaemonBox.ItemIndex := 0;
  renderStatuses('Готовим первоначальный опрос…');
end;

procedure TMonitorForm.setBusy(aBusy: Boolean);
begin
  Fbusy := aBusy;
  FstartButton.Enabled := not aBusy;
  FstopButton.Enabled := not aBusy;
  FrestartButton.Enabled := not aBusy;
  FrefreshButton.Enabled := not aBusy;
end;

function TMonitorForm.footerNote: string;
begin
  if FlastUpdated > 0 then
    Result := 'Последнее обновление: ' + FormatDateTime('hh:nn:ss', FlastUpdated)
  else
    Result := 'Ещё не обновлялось';
  if FautoRefreshCheck.Checked then
    Result := Result + ' · авто-обновление каждые ' + IntToStr(FtimeoutSpin.Value) + ' с'
  else
    Result := Result + ' · режим: Manual (кнопка Refresh)';
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
    html.Add('<p style="color:#6b7280">CLI: ' + htmlEscape(FmonitorExe) + '</p>');
    html.Add('</body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

procedure TMonitorForm.renderStatuses(const aNote: string);
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
    for idx := 0 to High(Fstatuses) do
    begin
      s := Fstatuses[idx];
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
    html.Add('<p class="muted" style="margin-top:14px;">' + htmlEscape(aNote) + '</p>');
    html.Add('</body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

{ Первоначальный полный опрос — прогрессивно, по одному демону (видно прогрев). }
procedure TMonitorForm.initialRefresh;
var
  idx: Integer;
  json: string;
  one: TGuiStatuses;
begin
  if Fbusy then
    Exit;
  if FloadError <> '' then
  begin
    renderError(FloadError);
    Exit;
  end;

  setBusy(True);
  Screen.Cursor := crAppStart;
  try
    for idx := 0 to High(Finv) do
    begin
      Fstatuses[idx].State := 'проверка…';
      renderStatuses(Format('Первоначальный опрос %d/%d: %s (%s:%d)…',
        [idx + 1, Length(Finv), Finv[idx].Name, Finv[idx].Host, Finv[idx].Port]));
      Application.ProcessMessages;

      if runMonitor(['status', Finv[idx].Name, '--json'], json)
        and parseStatuses(json, one) and (Length(one) = 1) then
        Fstatuses[idx] := one[0]
      else
      begin
        Fstatuses[idx].State := 'down';
        Fstatuses[idx].Reachable := False;
        Fstatuses[idx].Pid := 0;
      end;
      Application.ProcessMessages;
    end;
    FlastUpdated := Now;
  finally
    Screen.Cursor := crDefault;
    setBusy(False);
  end;
  renderStatuses(footerNote);
end;

{ Обычное обновление — тихий полный опрос одним вызовом, без «проверки» по строкам. }
procedure TMonitorForm.quietRefresh;
var
  json: string;
  all: TGuiStatuses;
begin
  if Fbusy then
    Exit;
  if FloadError <> '' then
  begin
    renderError(FloadError);
    Exit;
  end;

  setBusy(True);
  Screen.Cursor := crAppStart;
  renderStatuses('Обновление…');
  Application.ProcessMessages;
  try
    if runMonitor(['status', '--json'], json) and parseStatuses(json, all) and (Length(all) = Length(Fstatuses)) then
      Fstatuses := all;
    FlastUpdated := Now;
  finally
    Screen.Cursor := crDefault;
    setBusy(False);
  end;
  renderStatuses(footerNote);
end;

procedure TMonitorForm.applyRefreshMode;
begin
  if FautoRefreshCheck.Checked then
  begin
    Ftimer.Interval := FtimeoutSpin.Value * 1000;
    Ftimer.Enabled := True;
  end
  else
    Ftimer.Enabled := False;
  { обновить подпись «режим …» }
  if not Fbusy then
    renderStatuses(footerNote);
end;

procedure TMonitorForm.onAutoRefreshChanged(Sender: TObject);
begin
  FtimeoutSpin.Enabled := FautoRefreshCheck.Checked;
  applyRefreshMode;
  if FautoRefreshCheck.Checked then
    quietRefresh;
end;

procedure TMonitorForm.onTimeoutChanged(Sender: TObject);
begin
  applyRefreshMode;
end;

procedure TMonitorForm.onTimer(Sender: TObject);
begin
  quietRefresh;
end;

procedure TMonitorForm.onRefreshClick(Sender: TObject);
begin
  quietRefresh;
end;

procedure TMonitorForm.asyncFirstRefresh(aData: PtrInt);
begin
  initialRefresh;
  applyRefreshMode;
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
  Screen.Cursor := crAppStart;
  renderStatuses(Format('%s: %s…', [aAction, daemonName]));
  Application.ProcessMessages;
  try
    runMonitor([aAction, daemonName], output);
  finally
    Screen.Cursor := crDefault;
    setBusy(False);
  end;

  quietRefresh;
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
  FloadError := '';
  FlastUpdated := 0;
  FmonitorExe := resolveMonitorExe;
  buildUi;

  try
    buildSkeleton;
  except
    on E: Exception do
    begin
      FloadError := 'Не удалось загрузить ' + inventoryPath + ': ' + E.Message;
      renderError(FloadError);
    end;
  end;

  { Первый (полный) опрос — асинхронно, ПОСЛЕ показа окна: UI появляется сразу. }
  Application.QueueAsyncCall(@asyncFirstRefresh, 0);
end;

end.
