unit echoctl_models;

{ Команды группы models. DF2.1 — list (манифест models-manifest.json + состояние на
  диске). download/delete — далее. Манифест портирован из control-panel/models-provision. }

{$mode objfpc}{$H+}

interface

function runModelsList(const aManifestPath: string; aJson: Boolean): Integer;
function runModelsDownload(const aManifestPath, aId: string; aJson: Boolean): Integer;
function runModelsDelete(const aManifestPath, aConfigPath, aId: string;
  aDryRun, aForce, aJson: Boolean): Integer;

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

function runModelsList(const aManifestPath: string; aJson: Boolean): Integer;
const
  ROW = '%-13s %-42s %-11s %-11s %s';
var
  repoRoot: string;
  manifest: TJSONObject;
  models: TJSONArray;
  arr: TJSONArray;
  info: TModelInfo;
  i: Integer;
begin
  if aManifestPath = '' then
    Exit(fail('models-manifest.json not found'));
  repoRoot := resolveRepoRoot;
  manifest := loadConfigObject(aManifestPath);
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

function findEntryById(aModels: TJSONArray; const aId: string): TJSONObject;
var
  i: Integer;
  e: TJSONObject;
begin
  for i := 0 to aModels.Count - 1 do
  begin
    e := aModels.Objects[i];
    if SameText(e.Get('id', ''), aId) then
      Exit(e);
  end;
  Result := nil;
end;

procedure reportDownload(aJson: Boolean; const aId, aStatus, aDetail: string; aExitCode: Integer);
var
  o: TJSONObject;
begin
  if aJson then
  begin
    o := TJSONObject.Create;
    try
      o.Add('id', aId);
      o.Add('status', aStatus);
      o.Add('detail', aDetail);
      o.Add('exit_code', aExitCode);
      WriteLn(o.FormatJSON());
    finally
      o.Free;
    end;
  end
  else
    WriteLn(Format('models download %s: %s (%s)', [aId, aStatus, aDetail]));
end;

{ Скачан ли уже (все файлы/каталог на месте). }
function entryDownloaded(aEntry: TJSONObject; const aRepoRoot: string): Boolean;
var
  info: TModelInfo;
begin
  info := computeInfo(aEntry, aRepoRoot);
  Result := info.Downloaded;
  info.Paths.Free;
end;

function runModelsDownload(const aManifestPath, aId: string; aJson: Boolean): Integer;
var
  repoRoot, scriptPath, comSpec, comLine, savedCwd, detail: string;
  manifest: TJSONObject;
  models: TJSONArray;
  entry, dlObj: TJSONObject;
  dl, argsNode: TJSONData;
  args: TJSONArray;
  i, exitCode: Integer;
begin
  if aManifestPath = '' then
    Exit(fail('models-manifest.json not found'));
  repoRoot := resolveRepoRoot;
  manifest := loadConfigObject(aManifestPath);
  try
    models := manifestModels(manifest);
    if models = nil then
      Exit(fail('manifest has no "models" array'));
    entry := findEntryById(models, aId);
    if entry = nil then
      Exit(fail('unknown model id: ' + aId));
    if entry.Get('external_dir', '') <> '' then
      Exit(fail(aId + ' is an external model (not script-downloadable)'));
    dl := entry.Find('download');
    if (dl = nil) or not (dl is TJSONObject) then
      Exit(fail(aId + ' is not script-downloadable (staged via a conversion script)'));
    dlObj := TJSONObject(dl);

    if entryDownloaded(entry, repoRoot) then
    begin
      reportDownload(aJson, aId, 'skipped', 'already downloaded', 0);
      Exit(EXIT_OK);
    end;

    scriptPath := IncludeTrailingPathDelimiter(repoRoot) +
      StringReplace(dlObj.Get('script', ''), '/', PathDelim, [rfReplaceAll]);
    comSpec := GetEnvironmentVariable('ComSpec');
    if comSpec = '' then
      comSpec := 'cmd.exe';
    comLine := '/c "' + scriptPath + '"';
    argsNode := dlObj.Find('args');
    if (argsNode <> nil) and (argsNode is TJSONArray) then
    begin
      args := TJSONArray(argsNode);
      for i := 0 to args.Count - 1 do
        comLine := comLine + ' ' + args.Strings[i];
    end;
    if aJson then
      comLine := comLine + ' 1>&2'; { держим stdout чистым под JSON-результат }

    if not aJson then
      WriteLn('models download ', aId, ': running ', scriptPath, ' ...');

    savedCwd := GetCurrentDir;
    SetCurrentDir(repoRoot);
    try
      exitCode := ExecuteProcess(comSpec, comLine);
    finally
      SetCurrentDir(savedCwd);
    end;

    if exitCode = 0 then
    begin
      if entryDownloaded(entry, repoRoot) then
        detail := 'downloaded'
      else
        detail := 'script ran but files still missing';
      reportDownload(aJson, aId, 'completed', detail, 0);
      Result := EXIT_OK;
    end
    else
    begin
      reportDownload(aJson, aId, 'failed', 'download script exit ' + IntToStr(exitCode), exitCode);
      Result := EXIT_RUNTIME;
    end;
  finally
    manifest.Free;
  end;
end;

function slToJsonArray(aList: TStringList): TJSONArray;
var
  i: Integer;
begin
  Result := TJSONArray.Create;
  for i := 0 to aList.Count - 1 do
    Result.Add(aList[i]);
end;

function runModelsDelete(const aManifestPath, aConfigPath, aId: string;
  aDryRun, aForce, aJson: Boolean): Integer;
var
  repoRoot, modelName, externalDir, abs: string;
  manifest, config, ws, entry, res: TJSONObject;
  models, files: TJSONArray;
  filesArr, wsNode: TJSONData;
  toDelete, refs, removedInstances, deletedFiles: TStringList;
  i, idx: Integer;
begin
  if aManifestPath = '' then
    Exit(fail('models-manifest.json not found'));
  repoRoot := resolveRepoRoot;

  manifest := loadConfigObject(aManifestPath);
  config := nil;
  toDelete := TStringList.Create;
  refs := TStringList.Create;
  removedInstances := TStringList.Create;
  deletedFiles := TStringList.Create;
  try
    models := manifestModels(manifest);
    if models = nil then
      Exit(fail('manifest has no "models" array'));
    entry := findEntryById(models, aId);
    if entry = nil then
      Exit(fail('unknown model id: ' + aId));
    modelName := entry.Get('model_name', '');
    externalDir := entry.Get('external_dir', '');

    { существующие файлы (file-based) }
    if externalDir = '' then
    begin
      filesArr := entry.Find('files');
      if (filesArr <> nil) and (filesArr is TJSONArray) then
      begin
        files := TJSONArray(filesArr);
        for i := 0 to files.Count - 1 do
        begin
          abs := IncludeTrailingPathDelimiter(repoRoot) +
            StringReplace(files.Strings[i], '/', PathDelim, [rfReplaceAll]);
          if FileExists(abs) then
            toDelete.Add(abs);
        end;
      end;
    end;

    { ссылающиеся инстансы ws_daemons (по model_name) }
    config := loadConfigObject(aConfigPath);
    wsNode := config.Find('ws_daemons');
    if (wsNode <> nil) and (wsNode is TJSONObject) then
      ws := TJSONObject(wsNode)
    else
      ws := nil;
    if (ws <> nil) and (modelName <> '') then
      for i := 0 to ws.Count - 1 do
        if SameText(ws.Objects[ws.Names[i]].Get('model_name', ''), modelName) then
          refs.Add(ws.Names[i]);

    { dry-run: превью, без изменений }
    if aDryRun then
    begin
      if aJson then
      begin
        res := TJSONObject.Create;
        try
          res.Add('id', aId);
          res.Add('dry_run', True);
          res.Add('files', slToJsonArray(toDelete));
          if externalDir <> '' then
            res.Add('external_dir', externalDir)
          else
            res.Add('external_dir', TJSONNull.Create);
          res.Add('referencing_instances', slToJsonArray(refs));
          res.Add('would_cascade', aForce);
          WriteLn(res.FormatJSON());
        finally
          res.Free;
        end;
      end
      else
      begin
        WriteLn('models delete ', aId, ' (dry-run): nothing will be changed');
        WriteLn('  files to delete: ', toDelete.Count);
        for i := 0 to toDelete.Count - 1 do
          WriteLn('    ', toDelete[i]);
        if externalDir <> '' then
          WriteLn('  external dir (kept): ', externalDir);
        if refs.Count > 0 then
        begin
          WriteLn('  referencing instances: ', refs.CommaText);
          if aForce then
            WriteLn('    -> would be removed (--force)')
          else
            WriteLn('    -> blocks delete (use --force to cascade)');
        end;
      end;
      Exit(EXIT_OK);
    end;

    { блокировки }
    if (externalDir <> '') and not aForce then
      Exit(fail(aId + ' is external (shared dir ' + externalDir +
        '); use --force to remove config refs (directory left in place)'));
    if (refs.Count > 0) and not aForce then
      Exit(fail(aId + ' is referenced by instances: ' + refs.CommaText +
        '; use --force to remove them too'));

    { удаление файлов }
    for i := 0 to toDelete.Count - 1 do
      if SysUtils.DeleteFile(toDelete[i]) then
        deletedFiles.Add(toDelete[i]);

    { каскадное удаление инстансов }
    if aForce and (refs.Count > 0) and (ws <> nil) then
    begin
      for i := 0 to refs.Count - 1 do
      begin
        idx := ws.IndexOfName(refs[i]);
        if idx >= 0 then
        begin
          ws.Delete(idx);
          removedInstances.Add(refs[i]);
        end;
      end;
      saveConfigAtomic(aConfigPath, config);
    end;

    if aJson then
    begin
      res := TJSONObject.Create;
      try
        res.Add('id', aId);
        res.Add('deleted_files', slToJsonArray(deletedFiles));
        res.Add('removed_instances', slToJsonArray(removedInstances));
        if externalDir <> '' then
          res.Add('external_dir_kept', externalDir)
        else
          res.Add('external_dir_kept', TJSONNull.Create);
        WriteLn(res.FormatJSON());
      finally
        res.Free;
      end;
    end
    else
    begin
      WriteLn(Format('deleted model %s: %d file(s) removed', [aId, deletedFiles.Count]));
      if removedInstances.Count > 0 then
        WriteLn('  removed instances: ', removedInstances.CommaText);
      if externalDir <> '' then
        WriteLn('  note: external directory ', externalDir,
          ' left in place (remove manually if desired)');
    end;
    Result := EXIT_OK;
  finally
    deletedFiles.Free;
    removedInstances.Free;
    refs.Free;
    toDelete.Free;
    if config <> nil then
      config.Free;
    manifest.Free;
  end;
end;

end.
