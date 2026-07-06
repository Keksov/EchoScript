unit echoctl_schema;

{ Схема per-instance настроек демонов (какие ключи допустимы для движка, их тип и
  диапазон). Зеркалит DAEMON_ENV_MAP/WS_DAEMON_FIELDS из control-panel: launch-
  настройки whisper (vad/пороги/gpu). У vosk тюнингуемых launch-настроек в v1 нет. }

{$mode objfpc}{$H+}

interface

uses
  fpjson;

type
  TSettingType = (stBool, stInt, stFloat);
  TSettingSpec = record
    Key: string;
    Kind: TSettingType;
    HasMin, HasMax: Boolean;
    MinVal, MaxVal: Double;
  end;

{ Спецификация ключа настройки для движка; False, если ключ недопустим. }
function findSettingSpec(const aEngine, aKey: string; out aSpec: TSettingSpec): Boolean;

{ Разбор строкового значения по типу → TJSONData (владелец — вызывающий).
  aError непустой при неуспехе. }
function parseSettingValue(const aSpec: TSettingSpec; const aRaw: string;
  out aValue: TJSONData; out aError: string): Boolean;

{ Человекочитаемый список допустимых ключей движка (для сообщений об ошибке). }
function engineKeyList(const aEngine: string): string;

{ ---- Настройки оркестратора (топ-уровень config.json), порт ORCHESTRATOR_FIELDS ---- }
type
  TOrchFieldKind = (ofInt, ofString, ofSelect);
  TOrchField = record
    Key: string;
    Kind: TOrchFieldKind;
    Reload: string;      { 'hot' | 'restart' }
    HasMin, HasMax: Boolean;
    MinVal, MaxVal: Int64;
    Picker: string;      { '' | 'directory' | 'file' }
    OptionsFrom: string; { '' | 'models' }
  end;

function runConfigGet(const aConfigPath: string; aJson: Boolean): Integer;
function runConfigSet(const aConfigPath, aKey, aValue: string; aJson: Boolean): Integer;
function runConfigSchema(aJson: Boolean): Integer;

implementation

uses
  SysUtils, echoctl_config, echoctl_common;

function mkSpec(const aKey: string; aKind: TSettingType;
  aHasMin: Boolean; aMin: Double; aHasMax: Boolean; aMax: Double): TSettingSpec;
begin
  Result.Key := aKey;
  Result.Kind := aKind;
  Result.HasMin := aHasMin;
  Result.MinVal := aMin;
  Result.HasMax := aHasMax;
  Result.MaxVal := aMax;
end;

function findSettingSpec(const aEngine, aKey: string; out aSpec: TSettingSpec): Boolean;
begin
  Result := True;
  if SameText(aEngine, 'whisper') then
  begin
    if SameText(aKey, 'vad') then
      aSpec := mkSpec(aKey, stBool, False, 0, False, 0)
    else if SameText(aKey, 'vad_threshold') then
      aSpec := mkSpec(aKey, stFloat, True, 0, True, 1)
    else if SameText(aKey, 'vad_speech_pad_ms') then
      aSpec := mkSpec(aKey, stInt, True, 0, True, 5000)
    else if SameText(aKey, 'no_speech_thold') then
      aSpec := mkSpec(aKey, stFloat, True, 0, True, 1)
    else if SameText(aKey, 'entropy_thold') then
      aSpec := mkSpec(aKey, stFloat, True, 0, False, 0)
    else if SameText(aKey, 'gpu') then
      aSpec := mkSpec(aKey, stBool, False, 0, False, 0)
    else if SameText(aKey, 'gpu_device') then
      aSpec := mkSpec(aKey, stInt, True, 0, True, 16)
    else
      Result := False;
  end
  else
    Result := False;
end;

function engineKeyList(const aEngine: string): string;
begin
  if SameText(aEngine, 'whisper') then
    Result := 'vad, vad_threshold, vad_speech_pad_ms, no_speech_thold, entropy_thold, gpu, gpu_device'
  else if SameText(aEngine, 'vosk') then
    Result := '(none in v1)'
  else
    Result := '(unknown engine)';
end;

function parseSettingValue(const aSpec: TSettingSpec; const aRaw: string;
  out aValue: TJSONData; out aError: string): Boolean;
var
  fs: TFormatSettings;
  s: string;
  i: Integer;
  f: Double;
begin
  aValue := nil;
  aError := '';
  s := Trim(aRaw);
  case aSpec.Kind of
    stBool:
      begin
        if SameText(s, 'true') or (s = '1') or SameText(s, 'yes') then
          aValue := TJSONBoolean.Create(True)
        else if SameText(s, 'false') or (s = '0') or SameText(s, 'no') then
          aValue := TJSONBoolean.Create(False)
        else
        begin
          aError := aSpec.Key + ': expected bool (true/false)';
          Exit(False);
        end;
      end;
    stInt:
      begin
        if not TryStrToInt(s, i) then
        begin
          aError := aSpec.Key + ': expected integer';
          Exit(False);
        end;
        if aSpec.HasMin and (i < aSpec.MinVal) then
        begin
          aError := Format('%s: below min %g', [aSpec.Key, aSpec.MinVal]);
          Exit(False);
        end;
        if aSpec.HasMax and (i > aSpec.MaxVal) then
        begin
          aError := Format('%s: above max %g', [aSpec.Key, aSpec.MaxVal]);
          Exit(False);
        end;
        aValue := TJSONIntegerNumber.Create(i);
      end;
    stFloat:
      begin
        fs := DefaultFormatSettings;
        fs.DecimalSeparator := '.';
        if not TryStrToFloat(s, f, fs) then
        begin
          aError := aSpec.Key + ': expected number';
          Exit(False);
        end;
        if aSpec.HasMin and (f < aSpec.MinVal) then
        begin
          aError := Format('%s: below min %g', [aSpec.Key, aSpec.MinVal]);
          Exit(False);
        end;
        if aSpec.HasMax and (f > aSpec.MaxVal) then
        begin
          aError := Format('%s: above max %g', [aSpec.Key, aSpec.MaxVal]);
          Exit(False);
        end;
        aValue := TJSONFloatNumber.Create(f);
      end;
  end;
  Result := True;
end;

const
  ORCH_FIELD_COUNT = 10;

function mkOrch(const aKey: string; aKind: TOrchFieldKind; const aReload: string;
  aHasMin: Boolean; aMin: Int64; aHasMax: Boolean; aMax: Int64;
  const aPicker, aOptionsFrom: string): TOrchField;
begin
  Result.Key := aKey;
  Result.Kind := aKind;
  Result.Reload := aReload;
  Result.HasMin := aHasMin;
  Result.MinVal := aMin;
  Result.HasMax := aHasMax;
  Result.MaxVal := aMax;
  Result.Picker := aPicker;
  Result.OptionsFrom := aOptionsFrom;
end;

function orchField(aIndex: Integer): TOrchField;
begin
  case aIndex of
    0: Result := mkOrch('max_workers', ofInt, 'restart', True, 1, True, 64, '', '');
    1: Result := mkOrch('poll_interval_ms', ofInt, 'hot', True, 100, True, 60000, '', '');
    2: Result := mkOrch('stream_window_ms', ofInt, 'hot', True, 1000, True, 600000, '', '');
    3: Result := mkOrch('stream_chunk_ms', ofInt, 'hot', True, 1000, True, 3600000, '', '');
    4: Result := mkOrch('daemon_registry_ttl_ms', ofInt, 'hot', True, 1000, True, 600000, '', '');
    5: Result := mkOrch('drop_stable_ms', ofInt, 'hot', True, 0, True, 600000, '', '');
    6: Result := mkOrch('max_requeue_attempts', ofInt, 'hot', True, 0, True, 100, '', '');
    7: Result := mkOrch('default_model', ofSelect, 'hot', False, 0, False, 0, '', 'models');
    8: Result := mkOrch('ffmpeg_path', ofString, 'hot', False, 0, False, 0, 'file', '');
    9: Result := mkOrch('jobs_root', ofString, 'restart', False, 0, False, 0, 'directory', '');
  else
    Result := mkOrch('', ofString, 'hot', False, 0, False, 0, '', '');
  end;
end;

function findOrchField(const aKey: string; out aField: TOrchField): Boolean;
var
  i: Integer;
begin
  for i := 0 to ORCH_FIELD_COUNT - 1 do
  begin
    aField := orchField(i);
    if SameText(aField.Key, aKey) then
      Exit(True);
  end;
  Result := False;
end;

function orchKindStr(aKind: TOrchFieldKind): string;
begin
  case aKind of
    ofInt: Result := 'int';
    ofSelect: Result := 'select';
  else
    Result := 'string';
  end;
end;

function runConfigGet(const aConfigPath: string; aJson: Boolean): Integer;
var
  config, res: TJSONObject;
  field: TOrchField;
  i: Integer;
begin
  config := loadConfigObject(aConfigPath);
  try
    if aJson then
    begin
      res := TJSONObject.Create;
      try
        for i := 0 to ORCH_FIELD_COUNT - 1 do
        begin
          field := orchField(i);
          if field.Kind = ofInt then
            res.Add(field.Key, config.Get(field.Key, Int64(0)))
          else
            res.Add(field.Key, config.Get(field.Key, ''));
        end;
        WriteLn(res.FormatJSON());
      finally
        res.Free;
      end;
    end
    else
      for i := 0 to ORCH_FIELD_COUNT - 1 do
      begin
        field := orchField(i);
        if field.Kind = ofInt then
          WriteLn(Format('%-24s %d', [field.Key, config.Get(field.Key, Int64(0))]))
        else
          WriteLn(Format('%-24s %s', [field.Key, config.Get(field.Key, '')]));
      end;
    Result := EXIT_OK;
  finally
    config.Free;
  end;
end;

function runConfigSet(const aConfigPath, aKey, aValue: string; aJson: Boolean): Integer;
var
  config, res: TJSONObject;
  field: TOrchField;
  iv: Integer;
begin
  if aKey = '' then
    Exit(fail('config set requires <key> <value>'));
  if not findOrchField(aKey, field) then
    Exit(fail('unknown setting: ' + aKey));
  config := loadConfigObject(aConfigPath);
  try
    case field.Kind of
      ofInt:
        begin
          if not TryStrToInt(Trim(aValue), iv) then
            Exit(fail(aKey + ': expected integer'));
          if field.HasMin and (iv < field.MinVal) then
            Exit(fail(Format('%s: below min %d', [aKey, field.MinVal])));
          if field.HasMax and (iv > field.MaxVal) then
            Exit(fail(Format('%s: above max %d', [aKey, field.MaxVal])));
          config.Integers[aKey] := iv;
        end;
    else
      config.Strings[aKey] := aValue;
    end;
    saveConfigAtomic(aConfigPath, config);

    if aJson then
    begin
      res := TJSONObject.Create;
      try
        res.Add('key', aKey);
        if field.Kind = ofInt then
          res.Add('value', StrToIntDef(Trim(aValue), 0))
        else
          res.Add('value', aValue);
        res.Add('reload', field.Reload);
        WriteLn(res.FormatJSON());
      finally
        res.Free;
      end;
    end
    else
      WriteLn(Format('set %s=%s (reload: %s)', [aKey, aValue, field.Reload]));
    Result := EXIT_OK;
  finally
    config.Free;
  end;
end;

function runConfigSchema(aJson: Boolean): Integer;
const
  ROW = '%-24s %-8s %-8s %s';
var
  arr: TJSONArray;
  o: TJSONObject;
  field: TOrchField;
  i: Integer;
  extra: string;
begin
  if aJson then
  begin
    arr := TJSONArray.Create;
    try
      for i := 0 to ORCH_FIELD_COUNT - 1 do
      begin
        field := orchField(i);
        o := TJSONObject.Create;
        o.Add('key', field.Key);
        o.Add('type', orchKindStr(field.Kind));
        o.Add('reload', field.Reload);
        if field.HasMin then
          o.Add('min', field.MinVal);
        if field.HasMax then
          o.Add('max', field.MaxVal);
        if field.Picker <> '' then
          o.Add('picker', field.Picker);
        if field.OptionsFrom <> '' then
          o.Add('optionsFrom', field.OptionsFrom);
        arr.Add(o);
      end;
      WriteLn(arr.FormatJSON());
    finally
      arr.Free;
    end;
  end
  else
  begin
    WriteLn(Format(ROW, ['KEY', 'TYPE', 'RELOAD', 'RANGE/PICKER']));
    for i := 0 to ORCH_FIELD_COUNT - 1 do
    begin
      field := orchField(i);
      if field.Picker <> '' then
        extra := 'picker:' + field.Picker
      else if field.OptionsFrom <> '' then
        extra := 'options:' + field.OptionsFrom
      else if field.HasMin or field.HasMax then
        extra := Format('%d..%d', [field.MinVal, field.MaxVal])
      else
        extra := '';
      WriteLn(Format(ROW, [field.Key, orchKindStr(field.Kind), field.Reload, extra]));
    end;
  end;
  Result := EXIT_OK;
end;

end.
