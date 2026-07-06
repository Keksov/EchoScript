unit echoctl_models;

{ Команды группы models. DF2.1 — list (манифест models-manifest.json + состояние на
  диске). download/delete — далее. Манифест портирован из control-panel/models-provision. }

{$mode objfpc}{$H+}

interface

function runModelsList(aJson: Boolean): Integer;

implementation

uses
  SysUtils, Classes, fpjson, echoctl_config, echoctl_common;

type
  TModelInfo = record
    Id, Model, Kind, ModelName, Note: string;
    Downloadable, Downloaded, HasSize: Boolean;
    SizeMb: Double;
    Paths: TStringList; { владелец — вызывающий }
  end;

function manifestModels(aManifest: TJSONObject): TJSONArray;
var
  node: TJSONData;
begin
  node := aManifest.Find('models');
  if (node <> nil) and (node is TJSONArray) then
    Result := TJSONArray(node)
  else
    Result := nil;
end;

function fileSizeBytes(const aPath: string): Int64;
var
  sr: TSearchRec;
begin
  Result := -1;
  if FindFirst(aPath, faAnyFile, sr) = 0 then
  begin
    Result := sr.Size;
    FindClose(sr);
  end;
end;

function computeInfo(aEntry: TJSONObject; const aRepoRoot: string): TModelInfo;
var
  externalDir, abs: string;
  filesArr: TJSONData;
  files: TJSONArray;
  i, present: Integer;
  bytes, sz: Int64;
begin
  Result.Id := aEntry.Get('id', '');
  Result.Model := aEntry.Get('model', '');
  Result.Kind := aEntry.Get('kind', '');
  Result.ModelName := aEntry.Get('model_name', '');
  Result.Note := aEntry.Get('note', '');
  Result.HasSize := False;
  Result.SizeMb := 0;
  Result.Paths := TStringList.Create;

  externalDir := aEntry.Get('external_dir', '');
  if externalDir <> '' then
  begin
    Result.Downloadable := False;
    Result.Downloaded := DirectoryExists(externalDir);
    Result.Paths.Add(externalDir);
    Exit;
  end;

  Result.Downloadable := aEntry.Find('download') <> nil;
  bytes := 0;
  present := 0;
  filesArr := aEntry.Find('files');
  if (filesArr <> nil) and (filesArr is TJSONArray) then
  begin
    files := TJSONArray(filesArr);
    for i := 0 to files.Count - 1 do
    begin
      abs := IncludeTrailingPathDelimiter(aRepoRoot) + files.Strings[i];
      Result.Paths.Add(abs);
      sz := fileSizeBytes(abs);
      if sz > 0 then
      begin
        Inc(present);
        Inc(bytes, sz);
      end;
    end;
    Result.Downloaded := (present = files.Count) and (files.Count > 0);
  end
  else
    Result.Downloaded := False;

  if bytes > 0 then
  begin
    Result.HasSize := True;
    Result.SizeMb := Round((bytes / 1024 / 1024) * 10) / 10;
  end;
end;

function stateText(const aInfo: TModelInfo): string;
begin
  if aInfo.Downloaded then
    Result := 'downloaded'
  else if aInfo.Downloadable then
    Result := 'missing'
  else
    Result := 'absent';
end;

function sizeText(const aInfo: TModelInfo): string;
begin
  if aInfo.HasSize then
    Result := Format('%.1f MB', [aInfo.SizeMb])
  else
    Result := '-';
end;

function infoToJson(const aInfo: TModelInfo): TJSONObject;
var
  pathsArr: TJSONArray;
  i: Integer;
begin
  Result := TJSONObject.Create;
  Result.Add('id', aInfo.Id);
  Result.Add('model', aInfo.Model);
  Result.Add('kind', aInfo.Kind);
  Result.Add('model_name', aInfo.ModelName);
  Result.Add('downloadable', aInfo.Downloadable);
  Result.Add('downloaded', aInfo.Downloaded);
  if aInfo.HasSize then
    Result.Add('size_mb', aInfo.SizeMb)
  else
    Result.Add('size_mb', TJSONNull.Create);
  if aInfo.Note <> '' then
    Result.Add('note', aInfo.Note)
  else
    Result.Add('note', TJSONNull.Create);
  pathsArr := TJSONArray.Create;
  for i := 0 to aInfo.Paths.Count - 1 do
    pathsArr.Add(aInfo.Paths[i]);
  Result.Add('paths', pathsArr);
end;

function runModelsList(aJson: Boolean): Integer;
const
  ROW = '%-13s %-42s %-11s %-11s %s';
var
  manifestPath, repoRoot: string;
  manifest: TJSONObject;
  models: TJSONArray;
  arr: TJSONArray;
  info: TModelInfo;
  i: Integer;
begin
  manifestPath := findFileUpwards('models-manifest.json');
  if manifestPath = '' then
    Exit(fail('models-manifest.json not found'));
  repoRoot := resolveRepoRoot;
  manifest := loadConfigObject(manifestPath);
  try
    models := manifestModels(manifest);
    if models = nil then
      Exit(fail('manifest has no "models" array'));

    if aJson then
    begin
      arr := TJSONArray.Create;
      try
        for i := 0 to models.Count - 1 do
        begin
          info := computeInfo(models.Objects[i], repoRoot);
          try
            arr.Add(infoToJson(info));
          finally
            info.Paths.Free;
          end;
        end;
        WriteLn(arr.FormatJSON());
      finally
        arr.Free;
      end;
    end
    else
    begin
      WriteLn(Format(ROW, ['ID', 'MODEL', 'KIND', 'STATE', 'SIZE']));
      for i := 0 to models.Count - 1 do
      begin
        info := computeInfo(models.Objects[i], repoRoot);
        try
          WriteLn(Format(ROW, [info.Id, info.Model, info.Kind, stateText(info), sizeText(info)]));
        finally
          info.Paths.Free;
        end;
      end;
    end;
    Result := EXIT_OK;
  finally
    manifest.Free;
  end;
end;

end.
