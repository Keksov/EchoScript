program test_config;

{ Round-trip тест config I/O (PASCAL_RULES §8): load → saveAtomic → reload и
  проверка, что ВСЕ ключи (топ-уровень + ws_daemons) и опорные значения сохранены. }

{$mode objfpc}{$H+}
{$apptype console}

uses
  SysUtils, fpjson, echoctl_config;

var
  gPass: Integer = 0;
  gFail: Integer = 0;

procedure ok(const aName: string; aCond: Boolean);
begin
  if aCond then
  begin
    Inc(gPass);
    WriteLn('  ok   ', aName);
  end
  else
  begin
    Inc(gFail);
    WriteLn('  FAIL ', aName);
  end;
end;

function keyNames(aObj: TJSONObject): string;
var
  i: Integer;
begin
  Result := '';
  for i := 0 to aObj.Count - 1 do
    Result := Result + aObj.Names[i] + ';';
end;

var
  configPath: string;
  tempPath: string;
  original, reloaded: TJSONObject;
  wsOrig, wsReload: TJSONObject;
begin
  DefaultFormatSettings.DecimalSeparator := '.';

  if ParamCount >= 1 then
    configPath := ParamStr(1)
  else
    configPath := resolveDefaultConfigPath;

  WriteLn('test_config: ', configPath);
  original := loadConfigObject(configPath);
  try
    ok('config loaded as non-empty object', original.Count > 0);
    ok('has ws_daemons', original.Find('ws_daemons') <> nil);

    tempPath := configPath + '.roundtrip';
    saveConfigAtomic(tempPath, original);
    ok('roundtrip file written', FileExists(tempPath));

    reloaded := loadConfigObject(tempPath);
    try
      ok('top-level key count preserved', reloaded.Count = original.Count);
      ok('top-level key names preserved', keyNames(reloaded) = keyNames(original));
      ok('jobs_root value preserved',
        reloaded.Get('jobs_root', '#a') = original.Get('jobs_root', '#b'));
      ok('max_workers value preserved',
        reloaded.Get('max_workers', -1) = original.Get('max_workers', -2));

      wsOrig := original.Objects['ws_daemons'];
      wsReload := reloaded.Objects['ws_daemons'];
      ok('ws_daemons instance count preserved', wsReload.Count = wsOrig.Count);
      ok('ws_daemons instance names preserved', keyNames(wsReload) = keyNames(wsOrig));
    finally
      reloaded.Free;
    end;
    SysUtils.DeleteFile(tempPath);
  finally
    original.Free;
  end;

  WriteLn(Format('test_config: %d passed, %d failed', [gPass, gFail]));
  if gFail > 0 then
    ExitCode := 1
  else
    ExitCode := 0;
end.
