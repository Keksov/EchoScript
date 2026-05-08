program DiarizationDaemon;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  SysUtils,
  Classes,
  Dynlibs,
  SyncObjs,
  fpjson,
  Math,
  jsonparser,
  fpwebsocket,
  fpwebsocketserver,
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  fpcustwsserver;

type
  TFloatArray = array of Single;

  THintSegment = record
    SegmentId              : Integer;
    StartMs                : Int64;
    EndMs                  : Int64;
    Text                   : string;
    SpeakerId              : string;
  end;

  THintSegments = array of THintSegment;

  TDiarSegment = record
    SegmentId              : Integer;
    StartMs                : Int64;
    EndMs                  : Int64;
    SpeakerId              : string;
  end;

  TDiarTimeline = array of TDiarSegment;

  TModelWarmupState = (mwsNotStarted, mwsLoading, mwsReady, mwsFailed);

  TSherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig = record
    Model                  : PAnsiChar;
  end;

  TSherpaOnnxOfflineSpeakerSegmentationModelConfig = record
    Pyannote               : TSherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig;
    NumThreads             : LongInt;
    Debug                  : LongInt;
    Provider               : PAnsiChar;
  end;

  TSherpaOnnxFastClusteringConfig = record
    NumClusters            : LongInt;
    Threshold              : Single;
  end;

  TSherpaOnnxSpeakerEmbeddingExtractorConfig = record
    Model                  : PAnsiChar;
    NumThreads             : LongInt;
    Debug                  : LongInt;
    Provider               : PAnsiChar;
  end;

  TSherpaOnnxOfflineSpeakerDiarizationConfig = record
    Segmentation           : TSherpaOnnxOfflineSpeakerSegmentationModelConfig;
    Embedding              : TSherpaOnnxSpeakerEmbeddingExtractorConfig;
    Clustering             : TSherpaOnnxFastClusteringConfig;
    MinDurationOn          : Single;
    MinDurationOff         : Single;
  end;

  PTSherpaOnnxOfflineSpeakerDiarizationConfig = ^TSherpaOnnxOfflineSpeakerDiarizationConfig;

  TSherpaOnnxOfflineSpeakerDiarizationSegment = record
    Start                  : Single;
    Stop                   : Single;
    Speaker                : LongInt;
  end;

  PSherpaOnnxOfflineSpeakerDiarizationSegment = ^TSherpaOnnxOfflineSpeakerDiarizationSegment;

  TDiarizationDaemonOptions = record
    Host                   : string;
    Port                   : Word;
    SherpaDllPath          : string;
    SegModelPath           : string;
    EmbModelPath           : string;
    NumSpeakers            : LongInt;
    ClusterThreshold       : Single;
    MinDurationOn          : Single;
    MinDurationOff         : Single;
  end;

  TDiarizerCacheItem = record
    NumSpeakers            : LongInt;
    Handle                 : Pointer;
  end;

  TDiarizerCache = array of TDiarizerCacheItem;

  TDiarizationWarmupThread = class(TThread)
  protected
    procedure   Execute; override;
  public
    constructor Create;
  end;

  TDiarizationDaemonSession = class
  private
    Fstarted               : Boolean;
    FaudioBytes            : TBytes;
    FhintSegments          : THintSegments;
    FhintSegmentCount      : Integer;
    FsegmentHintsMode      : string;
    FrequestId             : string;
    FnumSpeakersOverride   : LongInt;
    Fconnection            : TWSConnection;
    procedure   appendAudioBytes(const aBytes: TBytes);
    procedure   clearSessionData;
    procedure   handleBinary(const aBytes: TBytes);
    procedure   handleCancel;
    procedure   handleFlush;
    procedure   handleSessionStart(const aRoot: TJSONObject);
    procedure   handleSetSegments(const aRoot: TJSONObject);
    procedure   runDiarization(out aTimeline: TDiarTimeline; out aSpeakerCount: Integer);
    function    findSpeakerForRange(const aTimeline: TDiarTimeline; aStartMs: Int64; aEndMs: Int64): string;
    function    bytesToPcmFloat(const aBytes: TBytes): TFloatArray;
    procedure   sendDiarFinal(aSpeakerCount: Integer; aDurationMs: Int64; const aSegments: THintSegments);
    procedure   sendDiarFinalFromTimeline(aSpeakerCount: Integer; aDurationMs: Int64; const aTimeline: TDiarTimeline);
    procedure   sendDiarSessionAck;
    procedure   sendWarning(const aMessage: string);
    procedure   sendError(const aMessage: string);
    procedure   sendEvent(aObject: TJSONObject);
    function    jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
    function    jsonStringOf(const aObject: TJSONObject; const aName: string): string;
  public
    constructor Create(aConnection: TWSConnection);
    procedure   handleMessage(const aMessage: TWSMessage);
  end;

  TDiarizationDaemonHost = class(TComponent)
  private
    Fserver                : TWebSocketServer;
    procedure   handleDisconnect(Sender: TObject);
    procedure   handleMessage(Sender: TObject; const aMessage: TWSMessage);
  public
    constructor Create(const aOptions: TDiarizationDaemonOptions);
    destructor  Destroy; override;
  end;

const
  DEFAULT_PORT           = 7900;
  MAX_SESSION_AUDIO_BYTES = 30 * 60 * 16000 * 2;
  SEGMENT_HINTS_MODE_OFF  = 'off';
  SEGMENT_HINTS_MODE_AUTO = 'auto';
  SEGMENT_HINTS_MODE_REQUIRED = 'required';

var
  gDaemonOptions         : TDiarizationDaemonOptions;
  gWarmupState           : TModelWarmupState = mwsNotStarted;
  gWarmupError           : string = '';
  gWarmupSignal          : TEvent = nil;
  gSherpaLock            : TRTLCriticalSection;
  gSherpaHandle          : TLibHandle = 0;
  gSherpaLoaded          : Boolean = False;
  gSherpaDllPath         : string = '';
  gDiarizerCache         : TDiarizerCache;
  gSherpaCreateOfflineSpeakerDiarization       : function(aConfig: PTSherpaOnnxOfflineSpeakerDiarizationConfig): Pointer; cdecl;
  gSherpaDestroyOfflineSpeakerDiarization      : procedure(aHandle: Pointer); cdecl;
  gSherpaOfflineSpeakerDiarizationGetSampleRate: function(aHandle: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers : function(aResult: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationResultGetNumSegments : function(aResult: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationResultSortByStartTime: function(aResult: Pointer): PSherpaOnnxOfflineSpeakerDiarizationSegment; cdecl;
  gSherpaOfflineSpeakerDiarizationDestroySegment       : procedure(aSegments: Pointer); cdecl;
  gSherpaOfflineSpeakerDiarizationProcess              : function(aHandle: Pointer; const aSamples: PSingle; aSampleCount: LongInt): Pointer; cdecl;
  gSherpaOfflineSpeakerDiarizationDestroyResult        : procedure(aResult: Pointer); cdecl;

{ ------------------------------------------------------------ }
{ Helpers                                                        }
{ ------------------------------------------------------------ }

procedure requireAssigned(const aProc: Pointer; const aName: string);
begin
  if aProc = nil then
    raise Exception.CreateFmt('Missing export: %s', [aName]);
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

function parseSingleValue(const aName: string; const aValue: string): Single;
var
  fs: TFormatSettings;
  parsed: Double;
  text: string;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  text := StringReplace(Trim(aValue), ',', '.', [rfReplaceAll]);
  if not TryStrToFloat(text, parsed, fs) then
    raise Exception.CreateFmt('Invalid float for %s: %s', [aName, aValue]);
  Result := parsed;
end;

function readEnvFloat(const aName: string; aDefault: Single): Single;
var
  value: string;
begin
  value := Trim(SysUtils.GetEnvironmentVariable(aName));
  if value = '' then
    Exit(aDefault);
  Result := parseSingleValue(aName, value);
end;

function readEnvInt64(const aName: string; aDefault: Int64): Int64;
var
  value: string;
begin
  value := Trim(SysUtils.GetEnvironmentVariable(aName));
  if value = '' then
    Exit(aDefault);
  Result := StrToInt64Def(value, aDefault);
end;

function getWorkspaceRootDir: string;
var
  idx: Integer;
  path: string;
begin
  { EXE lives at: services/diarizationdaemon/sherpa/build/x64/DiarizationDaemon.exe }
  { Go up 5 levels to reach the workspace root                                       }
  path := ExpandFileName(ExtractFileDir(ParamStr(0)));
  for idx := 1 to 5 do
    path := ExtractFileDir(path);
  Result := path;
end;

function resolveOptionalPath(const aPath: string): string;
begin
  Result := Trim(aPath);
  if Result = '' then
    Exit('');
  if ExtractFileDrive(Result) <> '' then
    Exit(ExpandFileName(Result));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(getWorkspaceRootDir) + Result);
end;

function resolveRequiredPath(const aPath: string; const aFallbackRelativePath: string): string;
begin
  if Trim(aPath) <> '' then
    Exit(resolveOptionalPath(aPath));
  Result := ExpandFileName(IncludeTrailingPathDelimiter(getWorkspaceRootDir) + aFallbackRelativePath);
end;

function resolveSherpaDllPath: string;
begin
  if Trim(gDaemonOptions.SherpaDllPath) <> '' then
    Exit(resolveOptionalPath(gDaemonOptions.SherpaDllPath));
  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) +
    'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
    'vendors' + PathDelim + 'sherpa-onnx' + PathDelim + 'sherpa-onnx.dll';
end;

{$ifdef MSWINDOWS}
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
{$endif}

{ ------------------------------------------------------------ }
{ Sherpa library                                                 }
{ ------------------------------------------------------------ }

procedure unloadSherpaLibrary;
var
  idx: Integer;
begin
  if Assigned(gSherpaDestroyOfflineSpeakerDiarization) then
  begin
    for idx := 0 to High(gDiarizerCache) do
    begin
      if gDiarizerCache[idx].Handle <> nil then
        gSherpaDestroyOfflineSpeakerDiarization(gDiarizerCache[idx].Handle);
    end;
  end;
  SetLength(gDiarizerCache, 0);

  if gSherpaHandle <> 0 then
    UnloadLibrary(gSherpaHandle);

  gSherpaHandle := 0;
  gSherpaDllPath := '';
  gSherpaLoaded := False;
  Pointer(gSherpaCreateOfflineSpeakerDiarization) := nil;
  Pointer(gSherpaDestroyOfflineSpeakerDiarization) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationGetSampleRate) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSegments) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultSortByStartTime) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationDestroySegment) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationProcess) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationDestroyResult) := nil;
end;

procedure loadSherpaLibrary;
var
  dllPath: string;
begin
  dllPath := ExpandFileName(resolveSherpaDllPath);

  if gSherpaLoaded then
  begin
    if SameText(gSherpaDllPath, dllPath) then
      Exit;
    unloadSherpaLibrary;
  end;

  if not FileExists(dllPath) then
    raise Exception.CreateFmt('sherpa-onnx.dll not found: %s', [dllPath]);

  {$ifdef MSWINDOWS}
  prependDirectoryToPath(ExtractFileDir(dllPath));
  gSherpaHandle := LoadLibraryEx(PChar(dllPath), 0, LOAD_WITH_ALTERED_SEARCH_PATH);
  {$else}
  gSherpaHandle := SafeLoadLibrary(dllPath);
  {$endif}
  if gSherpaHandle = 0 then
    raise Exception.CreateFmt('Failed to load sherpa-onnx.dll from: %s', [dllPath]);

  Pointer(gSherpaCreateOfflineSpeakerDiarization) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxCreateOfflineSpeakerDiarization');
  Pointer(gSherpaDestroyOfflineSpeakerDiarization) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxDestroyOfflineSpeakerDiarization');
  Pointer(gSherpaOfflineSpeakerDiarizationGetSampleRate) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationGetSampleRate');
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers');
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSegments) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments');
  Pointer(gSherpaOfflineSpeakerDiarizationResultSortByStartTime) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime');
  Pointer(gSherpaOfflineSpeakerDiarizationDestroySegment) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationDestroySegment');
  Pointer(gSherpaOfflineSpeakerDiarizationProcess) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationProcess');
  Pointer(gSherpaOfflineSpeakerDiarizationDestroyResult) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationDestroyResult');

  requireAssigned(Pointer(gSherpaCreateOfflineSpeakerDiarization), 'SherpaOnnxCreateOfflineSpeakerDiarization');
  requireAssigned(Pointer(gSherpaDestroyOfflineSpeakerDiarization), 'SherpaOnnxDestroyOfflineSpeakerDiarization');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationGetSampleRate), 'SherpaOnnxOfflineSpeakerDiarizationGetSampleRate');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers), 'SherpaOnnxOfflineSpeakerDiarizationResultGetNumSpeakers');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSegments), 'SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationResultSortByStartTime), 'SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationDestroySegment), 'SherpaOnnxOfflineSpeakerDiarizationDestroySegment');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationProcess), 'SherpaOnnxOfflineSpeakerDiarizationProcess');
  requireAssigned(Pointer(gSherpaOfflineSpeakerDiarizationDestroyResult), 'SherpaOnnxOfflineSpeakerDiarizationDestroyResult');

  gSherpaDllPath := dllPath;
  gSherpaLoaded := True;
end;

function normalizeNumSpeakers(aNumSpeakers: LongInt): LongInt;
begin
  if aNumSpeakers > 0 then
    Exit(aNumSpeakers);
  if gDaemonOptions.NumSpeakers > 0 then
    Exit(gDaemonOptions.NumSpeakers);
  Result := -1;
end;

function getOrCreateSpeakerDiarizer(aNumSpeakers: LongInt): Pointer;
var
  idx: Integer;
  diarizer: Pointer;
  config: TSherpaOnnxOfflineSpeakerDiarizationConfig;
  embPath: string;
  segPath: string;
  numSpeakers: LongInt;
begin
  numSpeakers := normalizeNumSpeakers(aNumSpeakers);

  EnterCriticalSection(gSherpaLock);
  try
    loadSherpaLibrary;

    for idx := 0 to High(gDiarizerCache) do
    begin
      if gDiarizerCache[idx].NumSpeakers = numSpeakers then
        Exit(gDiarizerCache[idx].Handle);
    end;

    segPath := resolveRequiredPath(
      gDaemonOptions.SegModelPath,
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'models' + PathDelim + 'segmentation.onnx'
    );
    embPath := resolveRequiredPath(
      gDaemonOptions.EmbModelPath,
      'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
      'models' + PathDelim + 'embedding.onnx'
    );

    if not FileExists(segPath) then
      raise Exception.CreateFmt('Speaker segmentation model not found: %s', [segPath]);
    if not FileExists(embPath) then
      raise Exception.CreateFmt('Speaker embedding model not found: %s', [embPath]);

    FillChar(config, SizeOf(config), 0);
    config.Segmentation.Pyannote.Model := PChar(segPath);
    config.Segmentation.NumThreads := 1;
    config.Segmentation.Debug := 0;
    config.Embedding.Model := PChar(embPath);
    config.Embedding.NumThreads := 1;
    config.Embedding.Debug := 0;

    config.Clustering.NumClusters := numSpeakers;

    config.Clustering.Threshold := gDaemonOptions.ClusterThreshold;
    config.MinDurationOn := gDaemonOptions.MinDurationOn;
    config.MinDurationOff := gDaemonOptions.MinDurationOff;

    diarizer := gSherpaCreateOfflineSpeakerDiarization(@config);
    if diarizer = nil then
      raise Exception.Create('SherpaOnnxCreateOfflineSpeakerDiarization returned nil');

    idx := Length(gDiarizerCache);
    SetLength(gDiarizerCache, idx + 1);
    gDiarizerCache[idx].NumSpeakers := numSpeakers;
    gDiarizerCache[idx].Handle := diarizer;

    Result := diarizer;
  finally
    LeaveCriticalSection(gSherpaLock);
  end;
end;

procedure ensureDiarizationAssetsAvailable;
var
  segPath: string;
  embPath: string;
  sherpaPath: string;
begin
  segPath := resolveRequiredPath(
    gDaemonOptions.SegModelPath,
    'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
    'models' + PathDelim + 'segmentation.onnx'
  );
  embPath := resolveRequiredPath(
    gDaemonOptions.EmbModelPath,
    'services' + PathDelim + 'diarizationdaemon' + PathDelim + 'sherpa' + PathDelim +
    'models' + PathDelim + 'embedding.onnx'
  );
  sherpaPath := resolveSherpaDllPath;

  if not FileExists(sherpaPath) then
    raise Exception.CreateFmt('Required sherpa runtime not found: %s', [sherpaPath]);
  if not FileExists(segPath) then
    raise Exception.CreateFmt('Required diarization segmentation model not found: %s', [segPath]);
  if not FileExists(embPath) then
    raise Exception.CreateFmt('Required diarization embedding model not found: %s', [embPath]);
end;

{ ------------------------------------------------------------ }
{ Warmup thread                                                  }
{ ------------------------------------------------------------ }

constructor TDiarizationWarmupThread.Create;
begin
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TDiarizationWarmupThread.Execute;
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
    { Load library and create diarizer with default num_speakers (-1 = auto) }
    getOrCreateSpeakerDiarizer(-1);
    gWarmupState := mwsReady;
    WriteLn('[diarizationdaemon] warmup ready');
  except
    on E: Exception do
    begin
      gWarmupError := E.Message;
      gWarmupState := mwsFailed;
      WriteLn(StdErr, '[diarizationdaemon] warmup failed: ', E.Message);
    end;
  end;

  if gWarmupSignal <> nil then
    gWarmupSignal.SetEvent;
end;

procedure startWarmup;
begin
  if gWarmupState <> mwsNotStarted then
    Exit;

  if gWarmupSignal = nil then
    gWarmupSignal := TEvent.Create(nil, True, False, '');

  gWarmupError := '';
  gWarmupState := mwsLoading;
  gWarmupSignal.ResetEvent;
  WriteLn('[diarizationdaemon] warmup started');
  TDiarizationWarmupThread.Create;
end;

procedure ensureWarmupReady;
begin
  if gWarmupState = mwsNotStarted then
    startWarmup;

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

{ ------------------------------------------------------------ }
{ TDiarizationDaemonSession                                      }
{ ------------------------------------------------------------ }

constructor TDiarizationDaemonSession.Create(aConnection: TWSConnection);
begin
  inherited Create;
  Fconnection := aConnection;
  FsegmentHintsMode := SEGMENT_HINTS_MODE_AUTO;
  FnumSpeakersOverride := -1;
end;

procedure TDiarizationDaemonSession.clearSessionData;
begin
  FaudioBytes := nil;
  FhintSegments := nil;
  FhintSegmentCount := 0;
  FsegmentHintsMode := SEGMENT_HINTS_MODE_AUTO;
  FrequestId := '';
  FnumSpeakersOverride := -1;
  Fstarted := False;
end;

procedure TDiarizationDaemonSession.appendAudioBytes(const aBytes: TBytes);
var
  existing: SizeInt;
  incoming: SizeInt;
begin
  existing := Length(FaudioBytes);
  incoming := Length(aBytes);
  if incoming = 0 then
    Exit;
  if existing + incoming > MAX_SESSION_AUDIO_BYTES then
  begin
    sendWarning('audio_buffer_full: max session audio exceeded, truncating');
    incoming := MAX_SESSION_AUDIO_BYTES - existing;
    if incoming <= 0 then
      Exit;
  end;
  SetLength(FaudioBytes, existing + incoming);
  Move(aBytes[0], FaudioBytes[existing], incoming);
end;

function TDiarizationDaemonSession.bytesToPcmFloat(const aBytes: TBytes): TFloatArray;
var
  idx: Integer;
  sample: SmallInt;
  sampleCount: Integer;
begin
  sampleCount := Length(aBytes) div 2;
  SetLength(Result, sampleCount);
  for idx := 0 to sampleCount - 1 do
  begin
    sample := SmallInt(aBytes[idx * 2] or (aBytes[idx * 2 + 1] shl 8));
    Result[idx] := sample / 32768.0;
  end;
end;

function TDiarizationDaemonSession.findSpeakerForRange(const aTimeline: TDiarTimeline; aStartMs: Int64; aEndMs: Int64): string;
var
  idx: Integer;
  bestMs: Int64;
  leftMs: Int64;
  rightMs: Int64;
  overlapMs: Int64;
begin
  Result := '';
  bestMs := 0;
  for idx := 0 to High(aTimeline) do
  begin
    leftMs := Max(aStartMs, aTimeline[idx].StartMs);
    rightMs := Min(aEndMs, aTimeline[idx].EndMs);
    overlapMs := rightMs - leftMs;
    if overlapMs <= 0 then
      Continue;
    if overlapMs > bestMs then
    begin
      bestMs := overlapMs;
      Result := aTimeline[idx].SpeakerId;
    end;
  end;
end;

procedure TDiarizationDaemonSession.runDiarization(out aTimeline: TDiarTimeline; out aSpeakerCount: Integer);
var
  diarizer: Pointer;
  diarizationResult: Pointer;
  diarizationSegments: PSherpaOnnxOfflineSpeakerDiarizationSegment;
  idx: Integer;
  pcm: TFloatArray;
  sampleRate: Integer;
  segmentCount: Integer;
begin
  SetLength(aTimeline, 0);
  aSpeakerCount := 0;

  ensureWarmupReady;

  pcm := bytesToPcmFloat(FaudioBytes);
  if Length(pcm) = 0 then
    Exit;

  diarizer := getOrCreateSpeakerDiarizer(FnumSpeakersOverride);

  EnterCriticalSection(gSherpaLock);
  try
    sampleRate := gSherpaOfflineSpeakerDiarizationGetSampleRate(diarizer);
    if sampleRate <> 16000 then
      raise Exception.CreateFmt('Unsupported diarization sample rate: %d', [sampleRate]);

    diarizationResult := gSherpaOfflineSpeakerDiarizationProcess(diarizer, @pcm[0], Length(pcm));
  finally
    LeaveCriticalSection(gSherpaLock);
  end;

  if diarizationResult = nil then
    raise Exception.Create('SherpaOnnxOfflineSpeakerDiarizationProcess returned nil');

  try
    aSpeakerCount := gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers(diarizationResult);
    segmentCount := gSherpaOfflineSpeakerDiarizationResultGetNumSegments(diarizationResult);
    if segmentCount <= 0 then
      Exit;

    diarizationSegments := gSherpaOfflineSpeakerDiarizationResultSortByStartTime(diarizationResult);
    try
      if diarizationSegments = nil then
        Exit;

      SetLength(aTimeline, segmentCount);
      for idx := 0 to segmentCount - 1 do
      begin
        aTimeline[idx].SegmentId := idx;
        aTimeline[idx].StartMs := Round(diarizationSegments[idx].Start * 1000.0);
        aTimeline[idx].EndMs := Round(diarizationSegments[idx].Stop * 1000.0);
        aTimeline[idx].SpeakerId := Format('spk_%d', [diarizationSegments[idx].Speaker]);
      end;
    finally
      if diarizationSegments <> nil then
        gSherpaOfflineSpeakerDiarizationDestroySegment(diarizationSegments);
    end;
  finally
    gSherpaOfflineSpeakerDiarizationDestroyResult(diarizationResult);
  end;
end;

procedure TDiarizationDaemonSession.sendEvent(aObject: TJSONObject);
begin
  if (aObject = nil) or (Fconnection = nil) then
    Exit;
  Fconnection.Send(UTF8String(aObject.AsJSON));
end;

procedure TDiarizationDaemonSession.sendError(const aMessage: string);
var
  obj: TJSONObject;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('event', 'diar_error');
    obj.Add('message', aMessage);
    sendEvent(obj);
  finally
    obj.Free;
  end;
end;

procedure TDiarizationDaemonSession.sendWarning(const aMessage: string);
var
  obj: TJSONObject;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('event', 'diar_warning');
    obj.Add('message', aMessage);
    sendEvent(obj);
  finally
    obj.Free;
  end;
end;

procedure TDiarizationDaemonSession.sendDiarSessionAck;
var
  obj: TJSONObject;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('event', 'diar_session_ack');
    obj.Add('engine', 'sherpa-onnx');
    obj.Add('segment_hints_mode', FsegmentHintsMode);
    obj.Add('connection_id', Fconnection.ConnectionID);
    if FrequestId <> '' then
      obj.Add('request_id', FrequestId);
    sendEvent(obj);
  finally
    obj.Free;
  end;
end;

function countUniqueSpeakersInHints(const aSegments: THintSegments): Integer;
var
  idx: Integer;
  jdx: Integer;
  found: Boolean;
  ids: array of string;
  count: Integer;
begin
  count := 0;
  SetLength(ids, 0);
  for idx := 0 to High(aSegments) do
  begin
    if aSegments[idx].SpeakerId = '' then
      Continue;
    found := False;
    for jdx := 0 to count - 1 do
      if ids[jdx] = aSegments[idx].SpeakerId then
      begin
        found := True;
        Break;
      end;
    if not found then
    begin
      SetLength(ids, count + 1);
      ids[count] := aSegments[idx].SpeakerId;
      Inc(count);
    end;
  end;
  Result := count;
end;

function countUniqueSpeakersInTimeline(const aTimeline: TDiarTimeline): Integer;
var
  idx: Integer;
  jdx: Integer;
  found: Boolean;
  ids: array of string;
  count: Integer;
begin
  count := 0;
  SetLength(ids, 0);
  for idx := 0 to High(aTimeline) do
  begin
    if aTimeline[idx].SpeakerId = '' then
      Continue;
    found := False;
    for jdx := 0 to count - 1 do
      if ids[jdx] = aTimeline[idx].SpeakerId then
      begin
        found := True;
        Break;
      end;
    if not found then
    begin
      SetLength(ids, count + 1);
      ids[count] := aTimeline[idx].SpeakerId;
      Inc(count);
    end;
  end;
  Result := count;
end;

procedure TDiarizationDaemonSession.sendDiarFinal(aSpeakerCount: Integer; aDurationMs: Int64; const aSegments: THintSegments);
var
  obj: TJSONObject;
  segArr: TJSONArray;
  seg: TJSONObject;
  idx: Integer;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('event', 'diar_final');
    obj.Add('engine', 'sherpa-onnx');
    obj.Add('speaker_count', countUniqueSpeakersInHints(aSegments));
    obj.Add('duration_ms', aDurationMs);
    if FrequestId <> '' then
      obj.Add('request_id', FrequestId);

    segArr := TJSONArray.Create;
    for idx := 0 to High(aSegments) do
    begin
      seg := TJSONObject.Create;
      seg.Add('segment_id', aSegments[idx].SegmentId);
      seg.Add('start_ms', aSegments[idx].StartMs);
      seg.Add('end_ms', aSegments[idx].EndMs);
      seg.Add('speaker_id', aSegments[idx].SpeakerId);
      seg.Add('text', aSegments[idx].Text);
      segArr.Add(seg);
    end;
    obj.Add('speaker_segments', segArr);

    sendEvent(obj);
  finally
    obj.Free;
  end;
end;

procedure TDiarizationDaemonSession.sendDiarFinalFromTimeline(aSpeakerCount: Integer; aDurationMs: Int64; const aTimeline: TDiarTimeline);
var
  obj: TJSONObject;
  segArr: TJSONArray;
  seg: TJSONObject;
  idx: Integer;
begin
  obj := TJSONObject.Create;
  try
    obj.Add('event', 'diar_final');
    obj.Add('engine', 'sherpa-onnx');
    obj.Add('speaker_count', countUniqueSpeakersInTimeline(aTimeline));
    obj.Add('duration_ms', aDurationMs);
    if FrequestId <> '' then
      obj.Add('request_id', FrequestId);

    segArr := TJSONArray.Create;
    for idx := 0 to High(aTimeline) do
    begin
      seg := TJSONObject.Create;
      seg.Add('segment_id', aTimeline[idx].SegmentId);
      seg.Add('start_ms', aTimeline[idx].StartMs);
      seg.Add('end_ms', aTimeline[idx].EndMs);
      seg.Add('speaker_id', aTimeline[idx].SpeakerId);
      seg.Add('text', '');
      segArr.Add(seg);
    end;
    obj.Add('speaker_segments', segArr);

    sendEvent(obj);
  finally
    obj.Free;
  end;
end;

function TDiarizationDaemonSession.jsonStringOf(const aObject: TJSONObject; const aName: string): string;
var
  node: TJSONData;
begin
  node := aObject.Find(aName);
  if (node = nil) or (node.JSONType = jtNull) then
    Exit('');
  Result := node.AsString;
end;

function TDiarizationDaemonSession.jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
var
  node: TJSONData;
begin
  node := aObject.Find(aName);
  if (node = nil) or (node.JSONType = jtNull) then
    Exit(0);
  Result := node.AsInteger;
end;

procedure TDiarizationDaemonSession.handleSessionStart(const aRoot: TJSONObject);
var
  channels: Integer;
  hintsMode: string;
  sampleFormat: string;
  sampleRate: Integer;
begin
  if Fstarted then
  begin
    sendError('session already started');
    Exit;
  end;

  WriteLn('[diarizationdaemon] diar_session_start');

  sampleRate := jsonIntOf(aRoot, 'sample_rate_hz');
  channels := jsonIntOf(aRoot, 'channels');
  sampleFormat := LowerCase(Trim(jsonStringOf(aRoot, 'audio_format')));
  if sampleRate <> 16000 then
    raise Exception.CreateFmt('Unsupported sample_rate_hz: %d', [sampleRate]);
  if channels <> 1 then
    raise Exception.CreateFmt('Unsupported channels: %d', [channels]);
  if sampleFormat <> 'pcm16le' then
    raise Exception.CreateFmt('Unsupported audio_format: %s', [sampleFormat]);

  clearSessionData;
  FrequestId := jsonStringOf(aRoot, 'request_id');
  FnumSpeakersOverride := jsonIntOf(aRoot, 'num_speakers');
  if FnumSpeakersOverride <= 0 then
    FnumSpeakersOverride := -1;

  hintsMode := LowerCase(Trim(jsonStringOf(aRoot, 'segment_hints_mode')));
  if (hintsMode = SEGMENT_HINTS_MODE_OFF) or
     (hintsMode = SEGMENT_HINTS_MODE_AUTO) or
     (hintsMode = SEGMENT_HINTS_MODE_REQUIRED) then
    FsegmentHintsMode := hintsMode
  else
    FsegmentHintsMode := SEGMENT_HINTS_MODE_AUTO;

  Fstarted := True;
  sendDiarSessionAck;
end;

procedure TDiarizationDaemonSession.handleSetSegments(const aRoot: TJSONObject);
var
  arr: TJSONArray;
  existing: Integer;
  idx: Integer;
  validCount: Integer;
  item: TJSONObject;
  node: TJSONData;
begin
  if not Fstarted then
  begin
    sendError('diar_set_segments received before diar_session_start');
    Exit;
  end;

  node := aRoot.Find('segments');
  if (node = nil) or (node.JSONType <> jtArray) then
  begin
    sendError('diar_set_segments: missing or invalid segments array');
    Exit;
  end;

  arr := TJSONArray(node);
  existing := FhintSegmentCount;
  validCount := 0;
  SetLength(FhintSegments, existing + arr.Count);

  for idx := 0 to arr.Count - 1 do
  begin
    if arr[idx].JSONType <> jtObject then
    begin
      sendWarning('diar_set_segments: skipped non-object segment entry');
      Continue;
    end;

    item := TJSONObject(arr[idx]);
    FhintSegments[existing + validCount].SegmentId := item.Get('segment_id', existing + validCount);
    FhintSegments[existing + validCount].StartMs := item.Get('start_ms', Int64(0));
    FhintSegments[existing + validCount].EndMs := item.Get('end_ms', Int64(0));
    FhintSegments[existing + validCount].Text := item.Get('text', '');
    FhintSegments[existing + validCount].SpeakerId := '';
    Inc(validCount);
  end;

  if validCount <> arr.Count then
    SetLength(FhintSegments, existing + validCount);
  FhintSegmentCount := existing + validCount;
end;

procedure TDiarizationDaemonSession.handleBinary(const aBytes: TBytes);
begin
  if not Fstarted then
  begin
    sendError('audio_chunk received before diar_session_start');
    Exit;
  end;
  appendAudioBytes(aBytes);
end;

procedure TDiarizationDaemonSession.handleFlush;
var
  durationMs: Int64;
  idx: Integer;
  speakerCount: Integer;
  timeline: TDiarTimeline;
begin
  WriteLn('[diarizationdaemon] diar_flush received');
  if not Fstarted then
  begin
    sendError('diar_flush received before diar_session_start');
    Exit;
  end;

  durationMs := Int64(Length(FaudioBytes)) * 1000 div (16000 * 2);

  try
    { Validate segment_hints_mode=required has hints }
    if (FsegmentHintsMode = SEGMENT_HINTS_MODE_REQUIRED) and (FhintSegmentCount = 0) then
    begin
      sendError('segment_hints_mode=required but no diar_set_segments received');
      Exit;
    end;

    if Length(FaudioBytes) = 0 then
    begin
      { No audio: send empty diar_final }
      if (FsegmentHintsMode <> SEGMENT_HINTS_MODE_OFF) and (FhintSegmentCount > 0) then
        sendDiarFinal(0, 0, Copy(FhintSegments, 0, FhintSegmentCount))
      else
      begin
        SetLength(timeline, 0);
        sendDiarFinalFromTimeline(0, 0, timeline);
      end;
      Exit;
    end;

    runDiarization(timeline, speakerCount);

    if (FsegmentHintsMode <> SEGMENT_HINTS_MODE_OFF) and (FhintSegmentCount > 0) then
    begin
      { Map speakers from timeline to hint segments by max overlap }
      for idx := 0 to FhintSegmentCount - 1 do
        FhintSegments[idx].SpeakerId := findSpeakerForRange(
          timeline,
          FhintSegments[idx].StartMs,
          FhintSegments[idx].EndMs
        );
      sendDiarFinal(speakerCount, durationMs, Copy(FhintSegments, 0, FhintSegmentCount));
    end
    else
      sendDiarFinalFromTimeline(speakerCount, durationMs, timeline);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, '[diarizationdaemon] diarization error: ', E.Message);
      sendError('diarization_failed: ' + Trim(E.Message));
    end;
  end;

  Fstarted := False;
  clearSessionData;
end;

procedure TDiarizationDaemonSession.handleCancel;
begin
  if not Fstarted then
    Exit;
  WriteLn('[diarizationdaemon] diar_cancel received');
  Fstarted := False;
  clearSessionData;
end;

procedure TDiarizationDaemonSession.handleMessage(const aMessage: TWSMessage);
var
  data: TJSONData;
  eventName: string;
  root: TJSONObject;
begin
  if not aMessage.IsText then
  begin
    handleBinary(aMessage.Payload);
    Exit;
  end;

  data := GetJSON(aMessage.AsString);
  try
    if data.JSONType <> jtObject then
      raise Exception.Create('Invalid websocket text payload');

    root := TJSONObject(data);
    eventName := LowerCase(Trim(jsonStringOf(root, 'event')));
    if eventName = 'diar_session_start' then
      handleSessionStart(root)
    else if eventName = 'diar_set_segments' then
      handleSetSegments(root)
    else if eventName = 'diar_flush' then
      handleFlush
    else if eventName = 'diar_cancel' then
      handleCancel
    else
      raise Exception.CreateFmt('Unsupported websocket event: %s', [eventName]);
  finally
    data.Free;
  end;
end;

{ ------------------------------------------------------------ }
{ TDiarizationDaemonHost                                         }
{ ------------------------------------------------------------ }

constructor TDiarizationDaemonHost.Create(const aOptions: TDiarizationDaemonOptions);
begin
  inherited Create(nil);
  Fserver := TWebSocketServer.Create(Self);
  Fserver.Host := aOptions.Host;
  Fserver.Port := aOptions.Port;
  Fserver.ThreadMode := wtmThread;
  Fserver.ThreadedAccept := True;
  Fserver.OnMessageReceived := @handleMessage;
  Fserver.OnDisconnect := @handleDisconnect;
  Fserver.Active := True;
  startWarmup;
end;

destructor TDiarizationDaemonHost.Destroy;
begin
  Fserver.Free;
  inherited Destroy;
end;

procedure TDiarizationDaemonHost.handleDisconnect(Sender: TObject);
begin
end;

procedure TDiarizationDaemonHost.handleMessage(Sender: TObject; const aMessage: TWSMessage);
var
  connection: TWSConnection;
  session: TDiarizationDaemonSession;
begin
  connection := TWSConnection(Sender);
  if connection.UserData = nil then
  begin
    connection.UserData := TDiarizationDaemonSession.Create(connection);
    connection.FreeUserData := True;
  end;

  session := TDiarizationDaemonSession(connection.UserData);
  try
    session.handleMessage(aMessage);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, '[diarizationdaemon] exception: ', E.Message);
      session.sendError(E.Message);
      raise;
    end;
  end;
end;

{ ------------------------------------------------------------ }
{ Command line parsing                                           }
{ ------------------------------------------------------------ }

procedure writeUsage;
begin
  WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [options]');
  WriteLn('  --host <value>                   listen host, default 127.0.0.1');
  WriteLn('  --port <value>                   listen port, default ', DEFAULT_PORT);
  WriteLn('  --sherpa-dll <path>              explicit sherpa-onnx.dll path override');
  WriteLn('  --seg-model <path>               speaker segmentation ONNX model path');
  WriteLn('  --emb-model <path>               speaker embedding ONNX model path');
  WriteLn('  --num-speakers <value>           fixed speaker count, default -1 (auto)');
  WriteLn('  --cluster-threshold <value>      clustering threshold, default 0.5');
  WriteLn('  --min-duration-on <value>        min active speech duration, default 0.2');
  WriteLn('  --min-duration-off <value>       min silence gap duration, default 0.5');
  WriteLn('  env: SHERPA_DLL_PATH, DIARIZE_SEG_MODEL, DIARIZE_EMB_MODEL');
  WriteLn('  env: DIARIZE_NUM_SPEAKERS, DIARIZE_CLUSTER_THRESHOLD');
  WriteLn('  env: DIARIZE_MIN_DURATION_ON, DIARIZE_MIN_DURATION_OFF');
end;

function parseCommandLine: TDiarizationDaemonOptions;
var
  arg: string;
  idx: Integer;
  val: string;
begin
  Result.Host := '127.0.0.1';
  Result.Port := DEFAULT_PORT;
  Result.SherpaDllPath := Trim(SysUtils.GetEnvironmentVariable('SHERPA_DLL_PATH'));
  Result.SegModelPath := Trim(SysUtils.GetEnvironmentVariable('DIARIZE_SEG_MODEL'));
  Result.EmbModelPath := Trim(SysUtils.GetEnvironmentVariable('DIARIZE_EMB_MODEL'));
  Result.NumSpeakers := readEnvInt64('DIARIZE_NUM_SPEAKERS', -1);
  Result.ClusterThreshold := readEnvFloat('DIARIZE_CLUSTER_THRESHOLD', 0.5);
  Result.MinDurationOn := readEnvFloat('DIARIZE_MIN_DURATION_ON', 0.2);
  Result.MinDurationOff := readEnvFloat('DIARIZE_MIN_DURATION_OFF', 0.5);

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
    else if arg = '--sherpa-dll' then
    begin
      Inc(idx);
      requireArgValue(idx, '--sherpa-dll', val);
      Result.SherpaDllPath := Trim(val);
    end
    else if arg = '--seg-model' then
    begin
      Inc(idx);
      requireArgValue(idx, '--seg-model', val);
      Result.SegModelPath := Trim(val);
    end
    else if arg = '--emb-model' then
    begin
      Inc(idx);
      requireArgValue(idx, '--emb-model', val);
      Result.EmbModelPath := Trim(val);
    end
    else if arg = '--num-speakers' then
    begin
      Inc(idx);
      requireArgValue(idx, '--num-speakers', val);
      Result.NumSpeakers := StrToInt64Def(Trim(val), -1);
    end
    else if arg = '--cluster-threshold' then
    begin
      Inc(idx);
      requireArgValue(idx, '--cluster-threshold', val);
      Result.ClusterThreshold := parseSingleValue('--cluster-threshold', val);
    end
    else if arg = '--min-duration-on' then
    begin
      Inc(idx);
      requireArgValue(idx, '--min-duration-on', val);
      Result.MinDurationOn := parseSingleValue('--min-duration-on', val);
    end
    else if arg = '--min-duration-off' then
    begin
      Inc(idx);
      requireArgValue(idx, '--min-duration-off', val);
      Result.MinDurationOff := parseSingleValue('--min-duration-off', val);
    end
    else
      raise Exception.CreateFmt('Unknown argument: %s', [arg]);

    Inc(idx);
  end;
end;

{ ------------------------------------------------------------ }
{ Main                                                           }
{ ------------------------------------------------------------ }

var
  host: TDiarizationDaemonHost;
  options: TDiarizationDaemonOptions;

begin
  host := nil;
  try
    InitCriticalSection(gSherpaLock);
    options := parseCommandLine;
    gDaemonOptions := options;
    ensureDiarizationAssetsAvailable;
    host := TDiarizationDaemonHost.Create(options);
    WriteLn('DiarizationDaemon listening on ws://', options.Host, ':', options.Port, '/');
    while True do
      Sleep(250);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, E.Message);
      Halt(1);
    end;
  end;

  { unreachable: daemon runs until the process is terminated }
  host.Free;
  DoneCriticalSection(gSherpaLock);
  gWarmupSignal.Free;
end.
