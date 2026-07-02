unit main_form;

{$mode objfpc}{$H+}

{ GUI-оболочка монитора. Окно показывается сразу (скелет из daemons.json), при старте
  полный опрос (прогрессивно). Режим Manual (кнопка Refresh) по умолчанию, либо
  Auto-refresh по таймеру (Timeout, сек). Управление демонами — прямо в гриде (ссылки
  Старт/Стоп/Рестарт на каждой строке). Клик по имени раскрывает карточку (аккордеон).
  Health/describe/управление — через CLI monitor; инвентарь — из monitor_core. }

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
  ExtCtrls,
  StdCtrls,
  Spin,
  Pixie.HtmlView,
  monitor_core;

type
  TGuiStatus = record
    Name        : string;
    Endpoint    : string;
    Port        : Integer;
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
    FexpandedName     : string;
    FdetailJson       : string;
    FpendingAct       : string;
    FpendingDaemon    : string;
    procedure   buildUi;
    procedure   buildSkeleton;
    procedure   asyncFirstRefresh({%H-}aData: PtrInt);
    procedure   handlePendingAnchor({%H-}aData: PtrInt);
    procedure   onRefreshClick({%H-}Sender: TObject);
    procedure   onTimer({%H-}Sender: TObject);
    procedure   onAutoRefreshChanged({%H-}Sender: TObject);
    procedure   onTimeoutChanged({%H-}Sender: TObject);
    procedure   applyRefreshMode;
    procedure   initialRefresh;
    procedure   quietRefresh;
    procedure   controlByName(const aAction, aName: string);
    procedure   setBusy(aBusy: Boolean);
    function    footerNote: string;
    function    resolveMonitorExe: string;
    function    inventoryPath: string;
    function    runMonitor(const aArgs: array of string; out aOutput: string): Boolean;
    function    parseStatuses(const aJson: string; out aStatuses: TGuiStatuses): Boolean;
    procedure   onAnchorClick({%H-}Sender: TObject; {%H-}El: TObject; const aUrl: string);
    function    detailCardHtml(const aStatus: TGuiStatus): string;
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
      aStatuses[idx].Port := obj.Get('port', 0);
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
  FtopPanel.Height := 84;
  FtopPanel.BevelOuter := bvNone;
  FtopPanel.Color := $00E6DED0;

  FtitleLabel := TLabel.Create(FtopPanel);
  FtitleLabel.Parent := FtopPanel;
  FtitleLabel.Left := 18;
  FtitleLabel.Top := 12;
  FtitleLabel.Caption := 'Daemon Monitor — статус и управление демонами распознавания';

  FautoRefreshCheck := TCheckBox.Create(FtopPanel);
  FautoRefreshCheck.Parent := FtopPanel;
  FautoRefreshCheck.Left := 18;
  FautoRefreshCheck.Top := 48;
  FautoRefreshCheck.Width := 140;
  FautoRefreshCheck.Caption := 'Auto-refresh';
  FautoRefreshCheck.Checked := False;   { Manual по умолчанию }
  FautoRefreshCheck.OnChange := @onAutoRefreshChanged;

  FtimeoutLabel := TLabel.Create(FtopPanel);
  FtimeoutLabel.Parent := FtopPanel;
  FtimeoutLabel.Left := 168;
  FtimeoutLabel.Top := 50;
  FtimeoutLabel.Caption := 'Timeout, сек:';

  FtimeoutSpin := TSpinEdit.Create(FtopPanel);
  FtimeoutSpin.Parent := FtopPanel;
  FtimeoutSpin.Left := 262;
  FtimeoutSpin.Top := 46;
  FtimeoutSpin.Width := 70;
  FtimeoutSpin.MinValue := 1;
  FtimeoutSpin.MaxValue := 3600;
  FtimeoutSpin.Value := 5;
  FtimeoutSpin.Enabled := False;   { активно только в режиме Auto-refresh }
  FtimeoutSpin.OnChange := @onTimeoutChanged;

  FrefreshButton := TButton.Create(FtopPanel);
  FrefreshButton.Parent := FtopPanel;
  FrefreshButton.Left := 620;
  FrefreshButton.Top := 45;
  FrefreshButton.Width := 120;
  FrefreshButton.Height := 28;
  FrefreshButton.Anchors := [akTop, akRight];
  FrefreshButton.Caption := 'Refresh';
  FrefreshButton.OnClick := @onRefreshClick;

  FhtmlView := TPixieHtmlView.Create(Self);
  FhtmlView.Parent := Self;
  FhtmlView.Align := alClient;
  FhtmlView.Color := $00F4F0E8;
  FhtmlView.OnAnchorClick := @onAnchorClick;

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
  for idx := 0 to High(Finv) do
  begin
    Fstatuses[idx].Name := Finv[idx].Name;
    Fstatuses[idx].Port := Finv[idx].Port;
    Fstatuses[idx].Endpoint := Finv[idx].Host + ':' + IntToStr(Finv[idx].Port);
    Fstatuses[idx].State := 'ожидание';
    Fstatuses[idx].Pid := 0;
    Fstatuses[idx].Reachable := False;
    Fstatuses[idx].Model := '';
  end;
  renderStatuses('Готовим первоначальный опрос…');
end;

procedure TMonitorForm.setBusy(aBusy: Boolean);
begin
  Fbusy := aBusy;
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

function TMonitorForm.detailCardHtml(const aStatus: TGuiStatus): string;
var
  invItem: TDaemonInventoryItem;
  hasInv: Boolean;
  data: TJSONData;
  root: TJSONObject;
  daeObj, inpObj, capObj, progObj: TJSONObject;
  engine, codec, langs, modes, fmt, html, bar, actJob: string;
  pct, wd, wt: Integer;

  function objOf(const aName: string): TJSONObject;
  var d: TJSONData;
  begin
    Result := nil;
    if root = nil then Exit;
    d := root.Find(aName);
    if (d <> nil) and (d.JSONType = jtObject) then
      Result := TJSONObject(d);
  end;

  function arrStr(aObj: TJSONObject; const aName: string): string;
  var d: TJSONData; a: TJSONArray; i: Integer;
  begin
    Result := '';
    if aObj = nil then Exit;
    d := aObj.Find(aName);
    if (d = nil) or (d.JSONType <> jtArray) then Exit;
    a := TJSONArray(d);
    for i := 0 to a.Count - 1 do
    begin
      if Result <> '' then Result := Result + ', ';
      Result := Result + a.Items[i].AsString;
    end;
  end;

  function boolStr(aObj: TJSONObject; const aName: string): string;
  var d: TJSONData;
  begin
    Result := '—';
    if aObj = nil then Exit;
    d := aObj.Find(aName);
    if (d <> nil) and (d.JSONType = jtBoolean) then
    begin
      if d.AsBoolean then Result := 'да' else Result := 'нет';
    end;
  end;

  function strOf(aObj: TJSONObject; const aName: string): string;
  var d: TJSONData;
  begin
    Result := '';
    if aObj = nil then Exit;
    d := aObj.Find(aName);
    if (d <> nil) and (d.JSONType <> jtNull) then Result := d.AsString;
  end;

  function intOf(aObj: TJSONObject; const aName: string): Integer;
  var d: TJSONData;
  begin
    Result := 0;
    if aObj = nil then Exit;
    d := aObj.Find(aName);
    if (d <> nil) and (d.JSONType = jtNumber) then Result := d.AsInteger;
  end;

  function row(const aLabel, aValue: string): string;
  begin
    Result := '<div style="display:flex;gap:10px;margin:3px 0;">' +
      '<div style="min-width:150px;color:#6b7280;">' + aLabel + '</div>' +
      '<div>' + aValue + '</div></div>';
  end;

begin
  hasInv := findDaemon(Finv, aStatus.Name, invItem);
  root := nil;
  data := nil;
  if Trim(FdetailJson) <> '' then
  begin
    try
      data := GetJSON(FdetailJson);
    except
      on E: Exception do
        data := nil;
    end;
    if (data <> nil) and (data.JSONType = jtObject) then
      root := TJSONObject(data);
  end;

  daeObj := objOf('daemon');
  inpObj := objOf('input');
  capObj := objOf('capabilities');

  engine := strOf(daeObj, 'engine');
  codec := strOf(inpObj, 'codec');
  if codec <> '' then
    fmt := codec + ' · ' + IntToStr(intOf(inpObj, 'sample_rate_hz')) + ' Hz · ' +
      IntToStr(intOf(inpObj, 'channels')) + ' ch'
  else
    fmt := '—';
  langs := arrStr(capObj, 'languages');
  modes := arrStr(capObj, 'modes');

  html := '<div style="padding:14px 18px;border-top:1px solid #e5dccd;">';
  html := html + '<div style="font-weight:600;margin-bottom:8px;">Подробности: ' + htmlEscape(aStatus.Name) + '</div>';
  html := html + row('Состояние', htmlEscape(aStatus.State) +
    '  ·  reachable: ' + BoolToStr(aStatus.Reachable, 'да', 'нет') +
    '  ·  PID: ' + BoolToStr(aStatus.Pid > 0, IntToStr(aStatus.Pid), '—'));
  html := html + row('Подключение', 'ws://' + htmlEscape(aStatus.Endpoint) + '/');
  if hasInv then
    html := html + row('Тип', htmlEscape(invItem.Kind) +
      BoolToStr(engine <> '', '  ·  движок: ' + htmlEscape(engine), ''));
  html := html + row('Модель', htmlEscape(aStatus.Model));

  if root <> nil then
  begin
    if root.Find('jobs_root') <> nil then
    begin
      { HTTP-демон (оркестратор / file-daemon) }
      html := html + row('Jobs-директория', htmlEscape(strOf(root, 'jobs_root')));
      html := html + row('Активная модель', htmlEscape(strOf(root, 'active_model')));
      actJob := strOf(root, 'active_job_id');
      html := html + row('Активная задача', BoolToStr(actJob <> '', htmlEscape(actJob), '—'));
      progObj := objOf('active_progress');
      if progObj <> nil then
      begin
        pct := intOf(progObj, 'progress_pct');
        wd := intOf(progObj, 'windows_done');
        wt := intOf(progObj, 'windows_total');
        bar := '<div style="display:inline-block;background:#e5dccd;border-radius:4px;height:10px;width:220px;vertical-align:middle;overflow:hidden;">' +
          '<div style="background:#4b8a5a;height:10px;width:' + IntToStr(pct) + '%;"></div></div>' +
          '<span style="margin-left:8px;">' + IntToStr(pct) + '% (' + IntToStr(wd) + '/' + IntToStr(wt) + ' окон)</span>';
        html := html + row('Прогресс', bar);
      end;
      html := html + row('Запущенные модели', htmlEscape(arrStr(root, 'running_models')));
    end
    else
    begin
      html := html + row('Формат входа', htmlEscape(fmt));
      html := html + row('Языки', htmlEscape(langs));
      html := html + row('Режимы', htmlEscape(modes));
      html := html + row('Диаризация', boolStr(capObj, 'diarization'));
      html := html + row('Word timestamps', boolStr(capObj, 'word_timestamps'));
      html := html + row('Streaming WS', boolStr(capObj, 'streaming_ws'));
      html := html + row('File API', boolStr(capObj, 'file_api'));
    end;
  end
  else
    html := html + row('Дескриптор', '<span style="color:#9a3412">недоступен (демон не отвечает)</span>');

  if hasInv then
  begin
    html := html + row('Start-скрипт', '<span style="color:#6b7280">' + htmlEscape(invItem.StartScript) + '</span>');
    html := html + row('Stop-скрипт', '<span style="color:#6b7280">' + htmlEscape(invItem.StopScript) + '</span>');
  end;

  html := html + '</div>';

  if data <> nil then
    data.Free;
  Result := html;
end;

procedure TMonitorForm.renderStatuses(const aNote: string);
var
  idx: Integer;
  s: TGuiStatus;
  html: TStringList;
  chevron: string;
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
    html.Add('.act{color:#1d4ed8;text-decoration:none;margin-right:10px;}');
    html.Add('</style></head><body>');
    html.Add('<h1>Демоны распознавания</h1>');
    html.Add('<table><tr><th>Демон</th><th>Статус</th><th>Endpoint</th><th>PID</th><th>Reachable</th><th>Модель</th><th>Действия</th></tr>');
    for idx := 0 to High(Fstatuses) do
    begin
      s := Fstatuses[idx];
      if s.Name = FexpandedName then
        chevron := '&#9662; '
      else
        chevron := '&#9656; ';
      html.Add(
        '<tr><td><a href="toggle:' + htmlEscape(s.Name) + '" style="text-decoration:none;color:#1c1917;font-weight:600">' +
          chevron + htmlEscape(s.Name) + '</a> <span style="color:#6b7280;font-weight:400">:' + IntToStr(s.Port) + '</span></td>' +
        '<td><span class="dot" style="background:' + stateColor(s.State) + '"></span>' +
          '<strong style="color:' + stateColor(s.State) + '">' + htmlEscape(s.State) + '</strong></td>' +
        '<td class="muted">' + htmlEscape(s.Endpoint) + '</td>' +
        '<td class="muted">' + BoolToStr(s.Pid > 0, IntToStr(s.Pid), '—') + '</td>' +
        '<td>' + BoolToStr(s.Reachable, 'да', 'нет') + '</td>' +
        '<td>' + htmlEscape(s.Model) + '</td>' +
        '<td>' +
          '<a class="act" href="start:' + htmlEscape(s.Name) + '">Старт</a>' +
          '<a class="act" href="stop:' + htmlEscape(s.Name) + '">Стоп</a>' +
          '<a class="act" href="restart:' + htmlEscape(s.Name) + '">Рестарт</a>' +
        '</td></tr>'
      );
      if s.Name = FexpandedName then
        html.Add('<tr><td colspan="7" style="padding:0;background:#f8f4ec;">' + detailCardHtml(s) + '</td></tr>');
    end;
    html.Add('</table>');
    html.Add('<p class="muted" style="margin-top:14px;">' + htmlEscape(aNote) + '</p>');
    html.Add('</body></html>');
    FhtmlView.LoadFromString(html.Text);
  finally
    html.Free;
  end;
end;

procedure TMonitorForm.onAnchorClick(Sender: TObject; El: TObject; const aUrl: string);
var
  colonPos: Integer;
begin
  colonPos := Pos(':', aUrl);
  if colonPos <= 0 then
    Exit;
  if Fbusy then
    Exit;
  { Defer everything out of this callback: re-rendering the HtmlView here frees the
    anchor element that Pixie still dereferences after OnAnchorClick returns, which
    causes an access violation. Stash the request and handle it on the next loop. }
  FpendingAct := Copy(aUrl, 1, colonPos - 1);
  FpendingDaemon := Copy(aUrl, colonPos + 1, MaxInt);
  if FpendingDaemon = '' then
    Exit;
  Application.QueueAsyncCall(@handlePendingAnchor, 0);
end;

procedure TMonitorForm.handlePendingAnchor(aData: PtrInt);
var
  act: string;
  daemonName: string;
  descJson: string;
begin
  act := FpendingAct;
  daemonName := FpendingDaemon;
  FpendingAct := '';
  FpendingDaemon := '';
  if daemonName = '' then
    Exit;
  if Fbusy then
    Exit;

  if act = 'toggle' then
  begin
    if SameText(FexpandedName, daemonName) then
    begin
      FexpandedName := '';
      FdetailJson := '';
      renderStatuses(footerNote);
      Exit;
    end;
    FexpandedName := daemonName;
    FdetailJson := '';
    setBusy(True);
    Screen.Cursor := crAppStart;
    try
      if runMonitor(['describe', daemonName], descJson) then
        FdetailJson := descJson;
    finally
      Screen.Cursor := crDefault;
      setBusy(False);
    end;
    renderStatuses(footerNote);
    Exit;
  end;

  if (act = 'start') or (act = 'stop') or (act = 'restart') then
    controlByName(act, daemonName);
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

procedure TMonitorForm.controlByName(const aAction, aName: string);
var
  output: string;
begin
  if Fbusy then
    Exit;
  if aName = '' then
    Exit;

  setBusy(True);
  Screen.Cursor := crAppStart;
  renderStatuses(Format('%s: %s…', [aAction, aName]));
  Application.ProcessMessages;
  try
    runMonitor([aAction, aName], output);
  finally
    Screen.Cursor := crDefault;
    setBusy(False);
  end;

  quietRefresh;
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

  Application.QueueAsyncCall(@asyncFirstRefresh, 0);
end;

end.
