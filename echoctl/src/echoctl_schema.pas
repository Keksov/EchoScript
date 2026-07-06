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

implementation

uses
  SysUtils;

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

end.
