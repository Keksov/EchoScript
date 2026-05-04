program VoskDaemon;

{$mode objfpc}{$H+}

uses
  SysUtils,
  Classes,
  Math,
  Dynlibs,
  SyncObjs,
  fpjson,
  jsonparser,
  fpwebsocket,
  fpwebsocketserver,
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  fpcustwsserver;

type
  PVoskModel = Pointer;
  PVoskRecognizer = Pointer;

  TModelWarmupState = (mwsNotStarted, mwsLoading, mwsReady, mwsFailed);

var
  gVoskHandle: TLibHandle = 0;
  gVoskLoaded: Boolean = False;
  gCachedModel: PVoskModel = nil;
  gVoskDllPath: string = '';
  gCachedModelPath: string = '';
  gWarmupError: string = '';
  gWarmupModelName: string = '';
  gWarmupSignal: TEvent = nil;
  gWarmupState: TModelWarmupState = mwsNotStarted;
  gModelNew: function(const aModelPath: PChar): PVoskModel; cdecl;
  gModelFree: procedure(aModel: PVoskModel); cdecl;
  gRecognizerNew: function(aModel: PVoskModel; aSampleRate: Single): PVoskRecognizer; cdecl;
  gRecognizerFree: procedure(aRecognizer: PVoskRecognizer); cdecl;
  gRecognizerAcceptWaveform: function(aRecognizer: PVoskRecognizer; const aData: Pointer; aLength: Integer): Integer; cdecl;
  gRecognizerPartialResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerFinalResult: function(aRecognizer: PVoskRecognizer): PChar; cdecl;
  gRecognizerSetWords: procedure(aRecognizer: PVoskRecognizer; aEnabled: Integer); cdecl;
  gRecognizerSetPartialWords: procedure(aRecognizer: PVoskRecognizer; aEnabled: Integer); cdecl;
  gSetLogLevel: procedure(aLevel: Integer); cdecl;

type
  TVoskDaemonOptions = record
    Host: string;
    Port: Word;
    ModelName: string;
  end;

  TVoskWarmupThread = class(TThread)
  private
    FModelName               : string;
  protected
    procedure   Execute; override;
  public
    constructor Create(const aModelName: string);
  end;

  TVoskDaemonSession = class
  private
    FConnection              : TWSConnection;
    FFinalText               : string;
    FLanguage                : string;
    FLastPartial             : string;
    FMode                    : string;
    FModelName               : string;
    FRecognizer              : PVoskRecognizer;
    FRequestId               : string;
    FSegmentIndex            : Integer;
    FStarted                 : Boolean;
    FProcessedSamples        : Integer;
    FLastBoundarySample      : Integer;
    function    jsonFloatOf(const aObject: TJSONObject; const aName: string; out aValue: Double): Boolean;
    function    jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
    function    jsonStringOf(const aObject: TJSONObject; const aName: string): string;
    function    parseTextPayload(const aJson: string; const aFieldName: string): string;
    function    safeCString(const aValue: PChar): string;
    procedure   appendTextWithSpace(var aTarget: string; const aValue: string);
    procedure   ensureRecognizer;
    procedure   freeRecognizer;
    procedure   handleBinary(const aBytes: TBytes);
    procedure   handleFlush;
    procedure   handleSessionStart(const aRoot: TJSONObject);
    procedure   parsePartialPayload(
      const aJson: string;
      aSampleRate: Integer;
      aFallbackStartSample: Integer;
      aFallbackEndSample: Integer;
      out aText: string;
      out aStartMs: Int64;
      out aEndMs: Int64
    );
    procedure   sendCommittedWords(const aJson: string; aSegmentId: Integer);
    procedure   sendError(const aMessage: string);
    procedure   sendEvent(aObject: TJSONObject);
    procedure   sendEventValue(const aEvent: string; const aText: string = '');
    procedure   sendPartialUpdate(const aText: string; aStartMs: Int64; aEndMs: Int64);
    procedure   sendSegmentFinal(const aText: string; aSegmentId: Integer; aStartSample: Integer; aEndSample: Integer);
  public
    constructor Create(aConnection: TWSConnection; const aModelName: string);
    destructor  Destroy; override;
    procedure   handleMessage(const aMessage: TWSMessage);
  end;

  TVoskDaemonHost = class(TComponent)
  private
    FModelName               : string;
    FServer                  : TWebSocketServer;
    procedure   handleDisconnect(Sender: TObject);
    procedure   handleMessage(Sender: TObject; const aMessage: TWSMessage);
  public
    constructor Create(const aOptions: TVoskDaemonOptions);
    destructor  Destroy; override;
  end;

procedure requireArgValue(aIndex: Integer; const aName: string; out aValue: string);
begin
  if aIndex > ParamCount then
    raise Exception.CreateFmt('Missing value for %s', [aName]);

  aValue := ParamStr(aIndex);
end;

function parsePort(const aValue: string): Word;
var
  portValue: Integer;
begin
  portValue := StrToIntDef(Trim(aValue), -1);
  if (portValue <= 0) or (portValue > High(Word)) then
    raise Exception.CreateFmt('Invalid port: %s', [aValue]);

  Result := Word(portValue);
end;

procedure writeUsage;
begin
  WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [options]');
  WriteLn('  --model-name <value>    model runtime: vosk_ru|vosk_ru_cmd|vosk_en');
  WriteLn('  --host <value>          listen host, default 127.0.0.1');
  WriteLn('  --port <value>          listen port, default 7701');
end;

function parseCommandLine: TVoskDaemonOptions;
var
  arg: string;
  val: string;
  idx: Integer;
begin
  Result.Host := '127.0.0.1';
  Result.Port := 7701;
  Result.ModelName := 'vosk_ru';

  idx := 1;
  while idx <= ParamCount do
  begin
    arg := ParamStr(idx);
    if (arg = '--help') or (arg = '-h') or (arg = '/?') then
    begin
      writeUsage;
      Halt(0);
    end
    else if arg = '--host' then
    begin
      Inc(idx);
      requireArgValue(idx, '--host', val);
      Result.Host := Trim(val);
    end
    else if arg = '--port' then
    begin
      Inc(idx);
      requireArgValue(idx, '--port', val);
      Result.Port := parsePort(val);
    end
    else if arg = '--model-name' then
    begin
      Inc(idx);
      requireArgValue(idx, '--model-name', val);
      Result.ModelName := Trim(val);
    end
    else
      raise Exception.CreateFmt('Unknown argument: %s', [arg]);

    Inc(idx);
  end;
end;

function getWorkspaceRootDir: string;
var
  idx: Integer;
  path: string;
begin
  path := ExpandFileName(ExtractFileDir(ParamStr(0)));
  for idx := 1 to 4 do
    path := ExtractFileDir(path);
  Result := path;
end;

function resolveVoskModelName(const aModelName: string): string;
begin
  if SameText(aModelName, 'vosk_en') then
    Exit('vosk-model-en-us-0.42-gigaspeech');

  if SameText(aModelName, 'vosk_ru_cmd') then
    Exit('vosk-model-small-ru-0.22');

  Result := 'vosk-model-ru-0.42';
end;

function resolveVoskDllPath(const aModelName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) +
    'services' + PathDelim + aModelName + PathDelim +
    'venv' + PathDelim + 'Lib' + PathDelim + 'site-packages' +
    PathDelim + 'vosk' + PathDelim + 'libvosk.dll';
end;

function resolveVoskModelsRoot: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('VOSK_MODELS_ROOT'));
  if Result = '' then
    Result := 'C:\var\vosk';
end;

function resolveVoskModelPath(const aModelName: string): string;
begin
  Result := IncludeTrailingPathDelimiter(resolveVoskModelsRoot) + resolveVoskModelName(aModelName);
end;

procedure prependDirectoryToPath(const aDirPath: string);
var
  envPath: string;
begin
  envPath := SysUtils.GetEnvironmentVariable('PATH');
  if Pos(UpperCase(aDirPath), UpperCase(envPath)) > 0 then
    Exit;

  if envPath = '' then
    Windows.SetEnvironmentVariable(PChar('PATH'), PChar(aDirPath))
  else
    Windows.SetEnvironmentVariable(PChar('PATH'), PChar(aDirPath + PathSeparator + envPath));
end;

procedure requireAssigned(const aProc: Pointer; const aName: string);
begin
  if aProc = nil then
    raise Exception.CreateFmt('Missing libvosk export: %s', [aName]);
end;

procedure freeCachedModel;
begin
  if (gCachedModel <> nil) and Assigned(gModelFree) then
    gModelFree(gCachedModel);

  gCachedModel := nil;
  gCachedModelPath := '';
end;

procedure unloadVoskLibrary;
begin
  freeCachedModel;

  if gVoskHandle <> 0 then
    UnloadLibrary(gVoskHandle);

  gVoskHandle := 0;
  gVoskDllPath := '';
  gVoskLoaded := False;
  Pointer(gModelNew) := nil;
  Pointer(gModelFree) := nil;
  Pointer(gRecognizerNew) := nil;
  Pointer(gRecognizerFree) := nil;
  Pointer(gRecognizerAcceptWaveform) := nil;
  Pointer(gRecognizerPartialResult) := nil;
  Pointer(gRecognizerResult) := nil;
  Pointer(gRecognizerFinalResult) := nil;
  Pointer(gRecognizerSetWords) := nil;
  Pointer(gRecognizerSetPartialWords) := nil;
  Pointer(gSetLogLevel) := nil;
end;

procedure loadVoskLibrary(const aModelName: string); forward;
function getOrCreateCachedModel(const aModelName: string): PVoskModel; forward;

constructor TVoskWarmupThread.Create(const aModelName: string);
begin
  FModelName := aModelName;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TVoskWarmupThread.Execute;
begin
  try
    SetExceptionMask([
      exInvalidOp,
      exDenormalized,
      exZeroDivide,
      exOverflow,
      exUnderflow,
      exPrecision
    ]);
    loadVoskLibrary(FModelName);
    getOrCreateCachedModel(FModelName);
    gWarmupState := mwsReady;
    WriteLn('[voskdaemon] warmup ready model=', FModelName);
  except
    on E: Exception do
    begin
      gWarmupError := E.Message;
      gWarmupState := mwsFailed;
      WriteLn(StdErr, '[voskdaemon] warmup failed: ', E.Message);
    end;
  end;

  if gWarmupSignal <> nil then
    gWarmupSignal.SetEvent;
end;

procedure loadVoskLibrary(const aModelName: string);
var
  dllPath: string;
begin
  dllPath := ExpandFileName(resolveVoskDllPath(aModelName));

  if gVoskLoaded then
  begin
    if SameText(gVoskDllPath, dllPath) then
      Exit;
    unloadVoskLibrary;
  end;

  if not FileExists(dllPath) then
    raise Exception.CreateFmt('libvosk.dll not found: %s', [dllPath]);

  prependDirectoryToPath(ExtractFileDir(dllPath));
  gVoskHandle := SafeLoadLibrary(dllPath);
  if gVoskHandle = 0 then
    raise Exception.CreateFmt('Failed to load libvosk.dll from: %s', [dllPath]);

  Pointer(gModelNew) := GetProcedureAddress(gVoskHandle, 'vosk_model_new');
  Pointer(gModelFree) := GetProcedureAddress(gVoskHandle, 'vosk_model_free');
  Pointer(gRecognizerNew) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_new');
  Pointer(gRecognizerFree) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_free');
  Pointer(gRecognizerAcceptWaveform) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_accept_waveform');
  Pointer(gRecognizerPartialResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_partial_result');
  Pointer(gRecognizerResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_result');
  Pointer(gRecognizerFinalResult) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_final_result');
  Pointer(gRecognizerSetWords) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_set_words');
  Pointer(gRecognizerSetPartialWords) := GetProcedureAddress(gVoskHandle, 'vosk_recognizer_set_partial_words');
  Pointer(gSetLogLevel) := GetProcedureAddress(gVoskHandle, 'vosk_set_log_level');

  requireAssigned(Pointer(gModelNew), 'vosk_model_new');
  requireAssigned(Pointer(gModelFree), 'vosk_model_free');
  requireAssigned(Pointer(gRecognizerNew), 'vosk_recognizer_new');
  requireAssigned(Pointer(gRecognizerFree), 'vosk_recognizer_free');
  requireAssigned(Pointer(gRecognizerAcceptWaveform), 'vosk_recognizer_accept_waveform');
  requireAssigned(Pointer(gRecognizerPartialResult), 'vosk_recognizer_partial_result');
  requireAssigned(Pointer(gRecognizerResult), 'vosk_recognizer_result');
  requireAssigned(Pointer(gRecognizerFinalResult), 'vosk_recognizer_final_result');
  requireAssigned(Pointer(gRecognizerSetWords), 'vosk_recognizer_set_words');
  requireAssigned(Pointer(gRecognizerSetPartialWords), 'vosk_recognizer_set_partial_words');
  requireAssigned(Pointer(gSetLogLevel), 'vosk_set_log_level');

  gVoskDllPath := dllPath;
  gVoskLoaded := True;
end;

function getOrCreateCachedModel(const aModelName: string): PVoskModel;
var
  modelPath: string;
begin
  modelPath := ExpandFileName(resolveVoskModelPath(aModelName));
  if not DirectoryExists(modelPath) then
    raise Exception.CreateFmt('Vosk model directory not found: %s', [modelPath]);

  if (gCachedModel <> nil) and SameText(gCachedModelPath, modelPath) then
    Exit(gCachedModel);

  freeCachedModel;
  gCachedModel := gModelNew(PChar(modelPath));
  if gCachedModel = nil then
    raise Exception.Create('vosk_model_new failed');

  gCachedModelPath := modelPath;
  Result := gCachedModel;
end;

procedure startWarmup(const aModelName: string);
begin
  if gWarmupState <> mwsNotStarted then
    Exit;

  if gWarmupSignal = nil then
    gWarmupSignal := TEvent.Create(nil, True, False, '');

  gWarmupError := '';
  gWarmupModelName := aModelName;
  gWarmupState := mwsLoading;
  gWarmupSignal.ResetEvent;
  WriteLn('[voskdaemon] warmup started model=', aModelName);
  TVoskWarmupThread.Create(aModelName);
end;

procedure ensureWarmupReady(const aModelName: string);
begin
  if gWarmupState = mwsNotStarted then
    startWarmup(aModelName);

  if gWarmupState = mwsLoading then
  begin
    if (gWarmupSignal = nil) or (gWarmupSignal.WaitFor(INFINITE) <> wrSignaled) then
      raise Exception.Create('Timed out waiting for daemon warmup');
  end;

  if gWarmupState = mwsFailed then
    raise Exception.Create(gWarmupError);

  if gWarmupState <> mwsReady then
    raise Exception.Create('Unexpected daemon warmup state');
end;

procedure preloadVoskAssets(const aModelName: string);
begin
  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);
  loadVoskLibrary(aModelName);
  getOrCreateCachedModel(aModelName);
end;

constructor TVoskDaemonSession.Create(aConnection: TWSConnection; const aModelName: string);
begin
  inherited Create;
  FConnection := aConnection;
  FFinalText := '';
  FLanguage := 'ru';
  FLastPartial := '';
  FMode := 'dictation';
  FModelName := aModelName;
  FRecognizer := nil;
  FRequestId := '';
  FSegmentIndex := 0;
  FStarted := False;
  FProcessedSamples := 0;
  FLastBoundarySample := 0;
end;

destructor TVoskDaemonSession.Destroy;
begin
  freeRecognizer;
  inherited Destroy;
end;

procedure TVoskDaemonSession.appendTextWithSpace(var aTarget: string; const aValue: string);
var
  value: string;
begin
  value := Trim(aValue);
  if value = '' then
    Exit;

  if aTarget = '' then
    aTarget := value
  else
    aTarget := aTarget + ' ' + value;
end;

procedure TVoskDaemonSession.ensureRecognizer;
var
  modelHandle: PVoskModel;
begin
  if FRecognizer <> nil then
    Exit;

  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);

  ensureWarmupReady(FModelName);
  loadVoskLibrary(FModelName);
  gSetLogLevel(-1);
  modelHandle := getOrCreateCachedModel(FModelName);
  FRecognizer := gRecognizerNew(modelHandle, 16000);
  if FRecognizer = nil then
    raise Exception.Create('vosk_recognizer_new failed');

  gRecognizerSetWords(FRecognizer, 1);
  gRecognizerSetPartialWords(FRecognizer, 1);
end;

procedure TVoskDaemonSession.freeRecognizer;
begin
  if FRecognizer <> nil then
    gRecognizerFree(FRecognizer);

  FRecognizer := nil;
end;

function TVoskDaemonSession.jsonFloatOf(const aObject: TJSONObject; const aName: string; out aValue: Double): Boolean;
var
  data: TJSONData;
begin
  Result := False;
  aValue := 0;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data = nil) or (data.JSONType = jtNull) then
    Exit;

  aValue := data.AsFloat;
  Result := True;
end;

function TVoskDaemonSession.jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
var
  data: TJSONData;
begin
  Result := 0;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsInteger;
end;

function TVoskDaemonSession.jsonStringOf(const aObject: TJSONObject; const aName: string): string;
var
  data: TJSONData;
begin
  Result := '';
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data <> nil) and (data.JSONType <> jtNull) then
    Result := data.AsString;
end;

function TVoskDaemonSession.parseTextPayload(const aJson: string; const aFieldName: string): string;
var
  data: TJSONData;
  root: TJSONObject;
begin
  Result := '';
  if Trim(aJson) = '' then
    Exit;

  data := GetJSON(aJson);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    Result := Trim(jsonStringOf(root, aFieldName));
  finally
    data.Free;
  end;
end;

procedure TVoskDaemonSession.parsePartialPayload(
  const aJson: string;
  aSampleRate: Integer;
  aFallbackStartSample: Integer;
  aFallbackEndSample: Integer;
  out aText: string;
  out aStartMs: Int64;
  out aEndMs: Int64
);
var
  data: TJSONData;
  root: TJSONObject;
  item: TJSONObject;
  words: TJSONArray;
  endSec: Double;
  startSec: Double;
begin
  aText := '';
  aStartMs := Round((aFallbackStartSample * 1000.0) / aSampleRate);
  aEndMs := Round((aFallbackEndSample * 1000.0) / aSampleRate);
  if Trim(aJson) = '' then
    Exit;

  data := GetJSON(aJson);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    aText := Trim(jsonStringOf(root, 'partial'));
    if aText = '' then
      Exit;

    if (root.Find('partial_result') = nil) or (root.Find('partial_result').JSONType <> jtArray) then
      Exit;

    words := TJSONArray(root.Find('partial_result'));
    if words.Count = 0 then
      Exit;

    if words.Objects[0] <> nil then
    begin
      item := words.Objects[0];
      if jsonFloatOf(item, 'start', startSec) then
        aStartMs := Round(startSec * 1000.0);
    end;

    if words.Objects[words.Count - 1] <> nil then
    begin
      item := words.Objects[words.Count - 1];
      if jsonFloatOf(item, 'end', endSec) then
        aEndMs := Round(endSec * 1000.0);
    end;
  finally
    data.Free;
  end;
end;

function TVoskDaemonSession.safeCString(const aValue: PChar): string;
var
  len: SizeInt;
  data: RawByteString;
begin
  Result := '';
  if aValue = nil then
    Exit;

  len := StrLen(aValue);
  if len <= 0 then
    Exit;

  SetLength(data, len);
  Move(aValue^, data[1], len);
  SetCodePage(data, 65001, False);
  Result := data;
end;

procedure TVoskDaemonSession.sendCommittedWords(const aJson: string; aSegmentId: Integer);
var
  data: TJSONData;
  item: TJSONObject;
  root: TJSONObject;
  words: TJSONArray;
  conf: Double;
  endSec: Double;
  idx: Integer;
  rootEvent: TJSONObject;
  startSec: Double;
begin
  if Trim(aJson) = '' then
    Exit;

  data := GetJSON(aJson);
  try
    if data.JSONType <> jtObject then
      Exit;

    root := TJSONObject(data);
    if (root.Find('result') = nil) or (root.Find('result').JSONType <> jtArray) then
      Exit;

    words := TJSONArray(root.Find('result'));
    for idx := 0 to words.Count - 1 do
    begin
      item := words.Objects[idx];
      if item = nil then
        Continue;

      rootEvent := TJSONObject.Create;
      try
        rootEvent.Add('event', 'word_committed');
        rootEvent.Add('text', Trim(jsonStringOf(item, 'word')));
        rootEvent.Add('index_in_segment', idx);
        rootEvent.Add('segment_id', aSegmentId);
        if jsonFloatOf(item, 'start', startSec) then
          rootEvent.Add('start_ms', Round(startSec * 1000.0));
        if jsonFloatOf(item, 'end', endSec) then
          rootEvent.Add('end_ms', Round(endSec * 1000.0));
        if jsonFloatOf(item, 'conf', conf) then
          rootEvent.Add('confidence', conf);
        sendEvent(rootEvent);
      finally
        rootEvent.Free;
      end;
    end;
  finally
    data.Free;
  end;
end;

procedure TVoskDaemonSession.sendSegmentFinal(const aText: string; aSegmentId: Integer; aStartSample: Integer; aEndSample: Integer);
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'segment_final');
    root.Add('text', aText);
    root.Add('segment_id', aSegmentId);
    root.Add('start_ms', Round(aStartSample / 16.0));
    root.Add('end_ms', Round(aEndSample / 16.0));
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TVoskDaemonSession.sendError(const aMessage: string);
var
  root: TJSONObject;
begin
  WriteLn(StdErr, '[voskdaemon] error: ', Trim(aMessage));
  root := TJSONObject.Create;
  try
    root.Add('event', 'error');
    root.Add('message', Trim(aMessage));
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TVoskDaemonSession.sendEvent(aObject: TJSONObject);
begin
  if (aObject = nil) or (FConnection = nil) then
    Exit;

  FConnection.Send(UTF8String(aObject.AsJSON));
end;

procedure TVoskDaemonSession.sendEventValue(const aEvent: string; const aText: string = '');
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', aEvent);
    if aText <> '' then
      root.Add('text', aText);
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TVoskDaemonSession.sendPartialUpdate(const aText: string; aStartMs: Int64; aEndMs: Int64);
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'partial_update');
    root.Add('text', aText);
    root.Add('start_ms', aStartMs);
    root.Add('end_ms', aEndMs);
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TVoskDaemonSession.handleBinary(const aBytes: TBytes);
var
  acc: Integer;
  endMs: Int64;
  startMs: Int64;
  partialJson: string;
  partialText: string;
  resultJson: string;
  resultText: string;
  segmentId: Integer;
begin
  if not FStarted then
  begin
    sendError('audio_chunk received before session_start');
    Exit;
  end;

  if FRecognizer = nil then
    WriteLn('[voskdaemon] first audio chunk bytes=', Length(aBytes));

  ensureRecognizer;

  if Length(aBytes) = 0 then
    Exit;

  acc := gRecognizerAcceptWaveform(FRecognizer, @aBytes[0], Length(aBytes));
  if acc < 0 then
    raise Exception.Create('vosk_recognizer_accept_waveform returned a negative status');

  Inc(FProcessedSamples, Length(aBytes) div SizeOf(SmallInt));
  if acc = 0 then
  begin
    partialJson := safeCString(gRecognizerPartialResult(FRecognizer));
    parsePartialPayload(
      partialJson,
      16000,
      FLastBoundarySample,
      FProcessedSamples,
      partialText,
      startMs,
      endMs
    );
    if (partialText <> '') and (partialText <> FLastPartial) then
    begin
      sendPartialUpdate(partialText, startMs, endMs);
      FLastPartial := partialText;
    end;
    Exit;
  end;

  resultJson := safeCString(gRecognizerResult(FRecognizer));
  resultText := parseTextPayload(resultJson, 'text');
  if resultText <> '' then
  begin
    segmentId := FSegmentIndex;
    sendCommittedWords(resultJson, segmentId);
    appendTextWithSpace(FFinalText, resultText);
    sendSegmentFinal(resultText, segmentId, FLastBoundarySample, FProcessedSamples);
    Inc(FSegmentIndex);
    FLastBoundarySample := FProcessedSamples;
  end;
  FLastPartial := '';
end;

procedure TVoskDaemonSession.handleFlush;
var
  finalJson: string;
  finalText: string;
  segmentId: Integer;
begin
  WriteLn('[voskdaemon] flush received');
  if not FStarted then
  begin
    sendError('flush received before session_start');
    Exit;
  end;

  finalJson := '';
  finalText := '';
  if FRecognizer <> nil then
  begin
    finalJson := safeCString(gRecognizerFinalResult(FRecognizer));
    finalText := parseTextPayload(finalJson, 'text');
  end;

  if finalText <> '' then
  begin
    segmentId := FSegmentIndex;
    sendCommittedWords(finalJson, segmentId);
    appendTextWithSpace(FFinalText, finalText);
    sendSegmentFinal(finalText, segmentId, FLastBoundarySample, FProcessedSamples);
    Inc(FSegmentIndex);
    FLastBoundarySample := FProcessedSamples;
  end;

  WriteLn('[voskdaemon] session_final text=', FFinalText);
  sendEventValue('session_final', FFinalText);
  FStarted := False;
  freeRecognizer;
end;

procedure TVoskDaemonSession.handleSessionStart(const aRoot: TJSONObject);
var
  ack: TJSONObject;
  channels: Integer;
  sampleRate: Integer;
  sampleFormat: string;
begin
  if FStarted then
  begin
    sendError('session already started');
    Exit;
  end;

  WriteLn('[voskdaemon] session_start model=', FModelName);

  sampleRate := jsonIntOf(aRoot, 'sample_rate_hz');
  channels := jsonIntOf(aRoot, 'channels');
  sampleFormat := LowerCase(Trim(jsonStringOf(aRoot, 'audio_format')));
  if sampleRate <> 16000 then
    raise Exception.CreateFmt('Unsupported sample_rate_hz: %d', [sampleRate]);
  if channels <> 1 then
    raise Exception.CreateFmt('Unsupported channels: %d', [channels]);
  if sampleFormat <> 'pcm16le' then
    raise Exception.CreateFmt('Unsupported audio_format: %s', [sampleFormat]);

  FLanguage := jsonStringOf(aRoot, 'language');
  FMode := jsonStringOf(aRoot, 'mode');
  FRequestId := jsonStringOf(aRoot, 'request_id');
  FFinalText := '';
  FLastPartial := '';
  FSegmentIndex := 0;
  FProcessedSamples := 0;
  FLastBoundarySample := 0;
  FStarted := True;

  ack := TJSONObject.Create;
  try
    ack.Add('event', 'session_ack');
    ack.Add('model_name', FModelName);
    ack.Add('language', FLanguage);
    ack.Add('mode', FMode);
    ack.Add('connection_id', FConnection.ConnectionID);
    if FRequestId <> '' then
      ack.Add('request_id', FRequestId);
    sendEvent(ack);
  finally
    ack.Free;
  end;
end;

procedure TVoskDaemonSession.handleMessage(const aMessage: TWSMessage);
var
  data: TJSONData;
  eventName: string;
  root: TJSONObject;
begin
  if not aMessage.IsText then
  begin
    handleBinary(aMessage.PayLoad);
    Exit;
  end;

  data := GetJSON(aMessage.AsString);
  try
    if data.JSONType <> jtObject then
      raise Exception.Create('Invalid websocket text payload');

    root := TJSONObject(data);
    eventName := LowerCase(Trim(jsonStringOf(root, 'event')));
    if eventName = 'session_start' then
      handleSessionStart(root)
    else if eventName = 'flush' then
      handleFlush
    else if eventName = 'cancel' then
    begin
      freeRecognizer;
      FStarted := False;
      sendEventValue('session_final', FFinalText);
    end
    else
      raise Exception.CreateFmt('Unsupported websocket event: %s', [eventName]);
  finally
    data.Free;
  end;
end;

constructor TVoskDaemonHost.Create(const aOptions: TVoskDaemonOptions);
begin
  inherited Create(nil);
  FModelName := aOptions.ModelName;
  FServer := TWebSocketServer.Create(Self);
  FServer.Host := aOptions.Host;
  FServer.Port := aOptions.Port;
  FServer.ThreadMode := wtmThread;
  FServer.ThreadedAccept := True;
  FServer.OnMessageReceived := @handleMessage;
  FServer.OnDisconnect := @handleDisconnect;
  FServer.Active := True;
  startWarmup(FModelName);
end;

destructor TVoskDaemonHost.Destroy;
begin
  FServer.Free;
  inherited Destroy;
end;

procedure TVoskDaemonHost.handleDisconnect(Sender: TObject);
begin
end;

procedure TVoskDaemonHost.handleMessage(Sender: TObject; const aMessage: TWSMessage);
var
  connection: TWSConnection;
  session: TVoskDaemonSession;
begin
  connection := TWSConnection(Sender);
  if connection.UserData = nil then
  begin
    connection.UserData := TVoskDaemonSession.Create(connection, FModelName);
    connection.FreeUserData := True;
  end;

  session := TVoskDaemonSession(connection.UserData);
  try
    session.handleMessage(aMessage);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, '[voskdaemon] exception: ', E.Message);
      session.sendError(E.Message);
      raise;
    end;
  end;
end;

var
  host: TVoskDaemonHost;
  options: TVoskDaemonOptions;

begin
  host := nil;
  try
    options := parseCommandLine;
    host := TVoskDaemonHost.Create(options);
    WriteLn('VoskDaemon listening on ws://', options.Host, ':', options.Port, '/ model=', options.ModelName);
    while True do
      Sleep(250);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;

  host.Free;
end.