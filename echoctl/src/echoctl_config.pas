unit echoctl_config;

{ config.json I/O для echoctl. Загрузка/сохранение работают на РАЗОБРАННОМ дереве
  fpjson, поэтому все неизвестные ключи (speech/models/ws_daemons/…) сохраняются —
  мутируем узлы, затем сериализуем целиком. Запись атомарна: temp-файл + MoveFileEx
  с MOVEFILE_REPLACE_EXISTING (истинная замена на NTFS, как rename в TS-версии). }

{$mode objfpc}{$H+}

interface

uses
  SysUtils, Classes, fpjson;

{ Загрузка config.json как JSON-объекта. Владелец результата — вызывающий (.Free). }
function loadConfigObject(const aPath: string): TJSONObject;

{ Атомарная запись объекта в aPath (форматированный JSON, 2-space). }
procedure saveConfigAtomic(const aPath: string; aRoot: TJSONObject);

{ Путь к config.json по расположению exe (echoctl/build/x64/echoctl.exe → корень
  репозитория), с фолбэком на текущий каталог. }
function resolveDefaultConfigPath: string;

implementation

uses
  jsonparser, Windows;

function readFileToString(const aPath: string): string;
var
  stream: TFileStream;
begin
  Result := '';
  stream := TFileStream.Create(aPath, fmOpenRead or fmShareDenyWrite);
  try
    if stream.Size > 0 then
    begin
      SetLength(Result, stream.Size);
      stream.ReadBuffer(Result[1], Length(Result));
    end;
  finally
    stream.Free;
  end;
end;

procedure writeStringToFile(const aPath, aContent: string);
var
  stream: TFileStream;
begin
  stream := TFileStream.Create(aPath, fmCreate);
  try
    if Length(aContent) > 0 then
      stream.WriteBuffer(aContent[1], Length(aContent));
  finally
    stream.Free;
  end;
end;

function loadConfigObject(const aPath: string): TJSONObject;
var
  raw: string;
  data: TJSONData;
begin
  if not FileExists(aPath) then
    raise Exception.CreateFmt('config not found: %s', [aPath]);
  raw := readFileToString(aPath);
  data := GetJSON(raw);
  if not (data is TJSONObject) then
  begin
    data.Free;
    raise Exception.CreateFmt('config root is not a JSON object: %s', [aPath]);
  end;
  Result := TJSONObject(data);
end;

procedure saveConfigAtomic(const aPath: string; aRoot: TJSONObject);
var
  tempPath: string;
  formatted: string;
begin
  formatted := aRoot.FormatJSON();
  tempPath := aPath + '.tmp';
  writeStringToFile(tempPath, formatted);
  if not MoveFileEx(PChar(tempPath), PChar(aPath), MOVEFILE_REPLACE_EXISTING) then
  begin
    SysUtils.DeleteFile(tempPath);
    raise Exception.CreateFmt('atomic replace failed (win err %d): %s -> %s',
      [Windows.GetLastError, tempPath, aPath]);
  end;
end;

function resolveDefaultConfigPath: string;
var
  dir: string;
  parent: string;
  candidate: string;
  depth: Integer;
begin
  dir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  for depth := 0 to 5 do
  begin
    candidate := IncludeTrailingPathDelimiter(dir) + 'config.json';
    if FileExists(candidate) then
      Exit(candidate);
    parent := ExtractFileDir(dir);
    if (parent = '') or (parent = dir) then
      Break;
    dir := parent;
  end;
  Result := IncludeTrailingPathDelimiter(GetCurrentDir) + 'config.json';
end;

end.
