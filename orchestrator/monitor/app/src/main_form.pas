unit main_form;

{$mode objfpc}{$H+}

{ GUI-оболочка монитора. WS-часть (fpwebsocket) отсутствует в FPC Lazarus, поэтому
  статусы берутся из CLI `monitor status --json` (собран VendorsCore FPC). GUI —
  тонкий фронт над CLI: рендер таблицы (Pixie) + кнопка/таймер обновления. }

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
  Pixie.HtmlView;

type
  TGuiStatus = record
    Name        : string;
    Endpoint    : string;
    State       : string;
    Reachable   : Boolean;
    Model       : string;
  end;
  TGuiStatuses = array of TGuiStatus;

  TMonitorForm = class(TForm)
    procedure FormCreate({%H-}Sender: TObject);
  private
    FhtmlView       : TPixieHtmlView;
    FtopPanel       : TPanel;
    FrefreshButton  : TButton;
    FtitleLabel     : TLabel;
    Ftimer          : TTimer;
    FmonitorExe     : string;
    procedure   buildUi;
    procedure   doRefresh({%H-}Sender: TObject);
    function    resolveMonitorExe: string;
    function    runMonitorJson(out aJson: string): Boolean;
    function    parseStatuses(const aJson: string; out aStatuses: TGuiStatuses): Boolean;
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

function TMonitorForm.runMonitorJson(out aJson: string): Boolean;
var
  proc: TProcess;
  buf: array[0..8191] of Byte;
  n: LongInt;
  outStream: TStringStream;
begin
  Result := False;
  aJson := '';
  if not FileExists(FmonitorExe) then
  begin
    aJson := '';
    Exit(False);
  end;

  proc := TProcess.Create(nil);
  outStream := TStringStream.Create('');
  try
    proc.Executable := FmonitorExe;
    proc.Parameters.Add('status');
    proc.Parameters.Add('--json');
    proc.Options := [poUsePipes, poNoConsole];
    proc.Execute;
    repeat
      n := proc.Output.Read(buf, SizeOf(buf));
      if n > 0 then
        outStream.Write(buf, n);
    until n <= 0;
    aJson := outStream.DataString;
    Result := Trim(aJson) <> '';
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
  FtopPanel.Height := 52;
  FtopPanel.BevelOuter := bvNone;
  FtopPanel.Color := $00E6DED0;

  FtitleLabel := TLabel.Create(FtopPanel);
  FtitleLabel.Parent := FtopPanel;
  FtitleLabel.Left := 18;
  FtitleLabel.Top := 18;
  FtitleLabel.Caption := 'Daemon Monitor — статус демонов распознавания';

  FrefreshButton := TButton.Create(FtopPanel);
  FrefreshButton.Parent := FtopPanel;
  FrefreshButton.Left := 620;
  FrefreshButton.Top := 12;
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
    html.Add('<table><tr><th>Демон</th><th>Статус</th><th>Endpoint</th><th>Reachable</th><th>Модель</th></tr>');
    for idx := 0 to High(aStatuses) do
    begin
      s := aStatuses[idx];
      html.Add(
        '<tr><td>' + htmlEscape(s.Name) + '</td>' +
        '<td><span class="dot" style="background:' + stateColor(s.State) + '"></span>' +
          '<strong style="color:' + stateColor(s.State) + '">' + htmlEscape(s.State) + '</strong></td>' +
        '<td class="muted">' + htmlEscape(s.Endpoint) + '</td>' +
        '<td>' + BoolToStr(s.Reachable, 'да', 'нет') + '</td>' +
        '<td>' + htmlEscape(s.Model) + '</td></tr>'
      );
    end;
    html.Add('</table>');
    html.Add('<p class="muted" style="margin-top:14px;">Автообновление каждые 5 с (через CLI monitor status --json).</p>');
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
  Screen.Cursor := crHourGlass;
  FrefreshButton.Enabled := False;
  try
    if not runMonitorJson(json) then
    begin
      renderError('Не удалось запустить CLI или пустой ответ.');
      Exit;
    end;
    if not parseStatuses(json, statuses) then
    begin
      renderError('Не удалось разобрать JSON статуса.');
      Exit;
    end;
    renderStatuses(statuses);
  finally
    FrefreshButton.Enabled := True;
    Screen.Cursor := crDefault;
  end;
end;

procedure TMonitorForm.FormCreate(Sender: TObject);
begin
  Caption := 'Daemon Monitor';
  FmonitorExe := resolveMonitorExe;
  buildUi;
  doRefresh(nil);
end;

end.
