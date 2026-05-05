program WhisperDaemon;

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
  PWhisperContext = Pointer;
  PWhisperState = Pointer;
  PWhisperToken = ^LongInt;

  TFloatArray = array of Single;
  TStringArray = array of string;
  TInt64Array = array of Int64;

  TSpeakerSegment = record
    SegmentId: Integer;
    StartMs: Int64;
    EndMs: Int64;
    SpeakerId: string;
    Text: string;
  end;

  TSpeakerSegments = array of TSpeakerSegment;

  TModelWarmupState = (mwsNotStarted, mwsLoading, mwsReady, mwsFailed);

  TWhisperTokenData = record
    id: LongInt;
    tid: LongInt;
    p: Single;
    plog: Single;
    pt: Single;
    ptsum: Single;
    t0: Int64;
    t1: Int64;
    tDtw: Int64;
    vlen: Single;
  end;

  TWhisperWordEvent = record
    Text: string;
    StartMs: Int64;
    EndMs: Int64;
    Confidence: Double;
    SegmentIndex: Integer;
    IndexInSegment: Integer;
  end;

  TWhisperWordEvents = array of TWhisperWordEvent;

  TWhisperAHead = record
    nTextLayer: LongInt;
    nHead: LongInt;
  end;
  PWhisperAHead = ^TWhisperAHead;

  TWhisperAHeads = record
    nHeads: SizeUInt;
    heads: PWhisperAHead;
  end;

  TWhisperContextParams = record
    useGpu: Boolean;
    flashAttn: Boolean;
    gpuDevice: LongInt;
    dtwTokenTimestamps: Boolean;
    dtwAheadsPreset: LongInt;
    dtwNTop: LongInt;
    dtwAheads: TWhisperAHeads;
    dtwMemSize: SizeUInt;
  end;

  TWhisperVadParams = record
    threshold: Single;
    minSpeechDurationMs: LongInt;
    minSilenceDurationMs: LongInt;
    maxSpeechDurationS: Single;
    speechPadMs: LongInt;
    samplesOverlap: Single;
  end;

  TWhisperGreedyParams = record
    bestOf: LongInt;
  end;

  TWhisperBeamSearchParams = record
    beamSize: LongInt;
    patience: Single;
  end;

  TWhisperFullParams = record
    strategy: LongInt;
    nThreads: LongInt;
    nMaxTextCtx: LongInt;
    offsetMs: LongInt;
    durationMs: LongInt;
    translate: Boolean;
    noContext: Boolean;
    noTimestamps: Boolean;
    singleSegment: Boolean;
    printSpecial: Boolean;
    printProgress: Boolean;
    printRealtime: Boolean;
    printTimestamps: Boolean;
    tokenTimestamps: Boolean;
    tholdPt: Single;
    tholdPtSum: Single;
    maxLen: LongInt;
    splitOnWord: Boolean;
    maxTokens: LongInt;
    debugMode: Boolean;
    audioCtx: LongInt;
    tdrzEnable: Boolean;
    suppressRegex: PChar;
    initialPrompt: PChar;
    carryInitialPrompt: Boolean;
    promptTokens: PWhisperToken;
    promptNTokens: LongInt;
    language: PChar;
    detectLanguage: Boolean;
    suppressBlank: Boolean;
    suppressNst: Boolean;
    temperature: Single;
    maxInitialTs: Single;
    lengthPenalty: Single;
    temperatureInc: Single;
    entropyThold: Single;
    logprobThold: Single;
    noSpeechThold: Single;
    greedy: TWhisperGreedyParams;
    beamSearch: TWhisperBeamSearchParams;
    newSegmentCallback: Pointer;
    newSegmentCallbackUserData: Pointer;
    progressCallback: Pointer;
    progressCallbackUserData: Pointer;
    encoderBeginCallback: Pointer;
    encoderBeginCallbackUserData: Pointer;
    abortCallback: Pointer;
    abortCallbackUserData: Pointer;
    logitsFilterCallback: Pointer;
    logitsFilterCallbackUserData: Pointer;
    grammarRules: Pointer;
    nGrammarRules: SizeUInt;
    iStartRule: SizeUInt;
    grammarPenalty: Single;
    vad: Boolean;
    vadModelPath: PChar;
    vadParams: TWhisperVadParams;
  end;

  TWhisperDaemonOptions = record
    Host: string;
    Port: Word;
    ModelName: string;
    UseGpu: Boolean;
    GpuDevice: LongInt;
    WhisperDllPath: string;
    ReleaseTag: string;
    SherpaDllPath: string;
    DiarizeSegModelPath: string;
    DiarizeEmbModelPath: string;
    DiarizeNumSpeakers: LongInt;
    DiarizeClusterThreshold: Single;
    DiarizeMinDurationOn: Single;
    DiarizeMinDurationOff: Single;
  end;

  TSherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig = record
    Model: PAnsiChar;
  end;

  TSherpaOnnxOfflineSpeakerSegmentationModelConfig = record
    Pyannote: TSherpaOnnxOfflineSpeakerSegmentationPyannoteModelConfig;
    NumThreads: LongInt;
    Debug: LongInt;
    Provider: PAnsiChar;
  end;

  TSherpaOnnxFastClusteringConfig = record
    NumClusters: LongInt;
    Threshold: Single;
  end;

  TSherpaOnnxSpeakerEmbeddingExtractorConfig = record
    Model: PAnsiChar;
    NumThreads: LongInt;
    Debug: LongInt;
    Provider: PAnsiChar;
  end;

  TSherpaOnnxOfflineSpeakerDiarizationConfig = record
    Segmentation: TSherpaOnnxOfflineSpeakerSegmentationModelConfig;
    Embedding: TSherpaOnnxSpeakerEmbeddingExtractorConfig;
    Clustering: TSherpaOnnxFastClusteringConfig;
    MinDurationOn: Single;
    MinDurationOff: Single;
  end;
  PTSherpaOnnxOfflineSpeakerDiarizationConfig = ^TSherpaOnnxOfflineSpeakerDiarizationConfig;

  TSherpaOnnxOfflineSpeakerDiarizationSegment = record
    Start: Single;
    Stop: Single;
    Speaker: LongInt;
  end;
  PSherpaOnnxOfflineSpeakerDiarizationSegment = ^TSherpaOnnxOfflineSpeakerDiarizationSegment;

  TWhisperWarmupThread = class(TThread)
  private
    FmodelName               : string;
  protected
    procedure   Execute; override;
  public
    constructor Create(const aModelName: string);
  end;

  TWhisperDaemonSession = class
  private
    Fmode                    : string;
    Fstarted                 : Boolean;
    FaudioBytes              : TBytes;
    Flanguage                : string;
    FresolvedLanguage        : string;
    FfinalText               : string;
    FmodelName               : string;
    FrequestId               : string;
    Fconnection              : TWSConnection;
    FsegmentCount            : Integer;
    FlastAutoCheckBytes      : SizeInt;
    FspeakerEmbeddings       : Boolean;
    FspeakerCount            : Integer;
    FspeakerSegments         : TSpeakerSegments;
    FfullSessionAudioBytes   : TBytes;
    procedure   appendAudioBytes(const aBytes: TBytes);
    procedure   appendFullSessionAudioBytes(const aBytes: TBytes);
    procedure   appendTextWithSpace(var aTarget: string; const aValue: string);
    procedure   appendWordEvent(
                  var aWordEvents: TWhisperWordEvents;
                  var aWordEventCount: Integer;
                  aSegmentIndex: Integer;
                  aIndexInSegment: Integer;
                  const aText: string;
                  aStartMs: Int64;
                  aEndMs: Int64;
                  aConfidence: Double
                );
    procedure   clearSessionData(aResetSummary: Boolean = True);
    procedure   clearDiarizationData;
    procedure   collectSegmentWords(
                  aContext: PWhisperContext;
                  aState: PWhisperState;
                  aWhisperSegmentIndex: LongInt;
                  aOutputSegmentIndex: Integer;
                  var aWordEvents: TWhisperWordEvents;
                  var aWordEventCount: Integer
                );
    procedure   inferBufferedAudio(
                  out aBatchText: string;
                  out aSegmentTexts: TStringArray;
                  out aSegmentT0s: TInt64Array;
                  out aSegmentT1s: TInt64Array;
                  out aWordEvents: TWhisperWordEvents;
                  out aWordEventCount: Integer;
                  out aCollectedCount: Integer
                );
    procedure   handleBinary(const aBytes: TBytes);
    procedure   handleFlush;
    procedure   processBufferedAudio(aFinalizeSession: Boolean);
    procedure   handleSessionStart(const aRoot: TJSONObject);
    procedure   runSpeakerDiarization;
    function    endsWithSentenceBoundary(const aText: string): Boolean;
    function    findSpeakerForRange(const aTimeline: TSpeakerSegments; aStartMs: Int64; aEndMs: Int64): string;
    procedure   sendError(const aMessage: string);
    procedure   sendWarning(const aMessage: string);
    procedure   sendEvent(aObject: TJSONObject);
    procedure   sendSessionFinal(aDurationMs: Int64);
    procedure   sendSegmentFinal(aSegmentId: Integer; const aText: string; aStartMs: Int64; aEndMs: Int64);
    procedure   sendWordCommitted(aSegmentId: Integer; aWordIndex: Integer; const aText: string; aStartMs: Int64; aEndMs: Int64; aConfidence: Double);
    function    bytesToPcmFloat(const aBytes: TBytes): TFloatArray;
    function    containsCjkCodepoint(const aText: string): Boolean;
    function    isClosingPunctuationToken(const aText: string): Boolean;
    function    isSpecialTokenText(const aText: string): Boolean;
    function    tokenHasLeadingSpace(const aText: string): Boolean;
    function    tokenWithoutLeadingSpaces(const aText: string): string;
    function    jsonBoolOf(const aObject: TJSONObject; const aName: string): Boolean;
    function    jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
    function    jsonStringOf(const aObject: TJSONObject; const aName: string): string;
    function    resolveDetectedLanguageCode(aState: PWhisperState): string;
    function    safeCString(const aValue: PChar): string;
  public
    constructor Create(aConnection: TWSConnection; const aModelName: string);
    procedure   handleMessage(const aMessage: TWSMessage);
  end;

  TWhisperDaemonHost = class(TComponent)
  private
    FmodelName               : string;
    Fserver                  : TWebSocketServer;
    procedure   handleDisconnect(Sender: TObject);
    procedure   handleMessage(Sender: TObject; const aMessage: TWSMessage);
  public
    constructor Create(const aOptions: TWhisperDaemonOptions);
    destructor  Destroy; override;
  end;

const
  WHISPER_SAMPLING_GREEDY = 0;
  WHISPER_SAMPLING_BEAM_SEARCH = 1;
  MAX_SESSION_AUDIO_BYTES = 30 * 60 * 16000 * 2;
  AUTO_FLUSH_MIN_BYTES = 8 * 16000 * 2;
  AUTO_FLUSH_STEP_BYTES = 3 * 16000 * 2;

var
  gWhisperHandle: TLibHandle = 0;
  gWhisperLoaded: Boolean = False;
  gCachedContext: PWhisperContext = nil;
  gDaemonOptions: TWhisperDaemonOptions;
  gWhisperDllPath: string = '';
  gCachedModelPath: string = '';
  gWarmupError: string = '';
  gWarmupModelName: string = '';
  gWarmupSignal: TEvent = nil;
  gInferenceLock: TRTLCriticalSection;
  gSherpaLock: TRTLCriticalSection;
  gWarmupState: TModelWarmupState = mwsNotStarted;
  gSherpaHandle: TLibHandle = 0;
  gSherpaLoaded: Boolean = False;
  gSherpaDllPath: string = '';
  gSpeakerDiarizer: Pointer = nil;
  gWhisperContextDefaultParams: function(): TWhisperContextParams; cdecl;
  gWhisperInitState: function(aContext: PWhisperContext): PWhisperState; cdecl;
  gWhisperFreeState: procedure(aState: PWhisperState); cdecl;
  gWhisperFree: procedure(aContext: PWhisperContext); cdecl;
  gWhisperVersion: function(): PChar; cdecl;
  gWhisperFullDefaultParams: function(aStrategy: LongInt): TWhisperFullParams; cdecl;
  gWhisperFullWithState: function(aContext: PWhisperContext; aState: PWhisperState; var aParams: TWhisperFullParams; const aSamples: PSingle; aSampleCount: LongInt): LongInt; cdecl;
  gWhisperFullNSegmentsFromState: function(aState: PWhisperState): LongInt; cdecl;
  gWhisperFullNTokensFromState: function(aState: PWhisperState; aSegmentIndex: LongInt): LongInt; cdecl;
  gWhisperInitFromFileWithParamsNoState: function(const aPathModel: PChar; var aParams: TWhisperContextParams): PWhisperContext; cdecl;
  gWhisperLangStr: function(aLanguageId: LongInt): PChar; cdecl;
  gWhisperFullLangIdFromState: function(aState: PWhisperState): LongInt; cdecl;
  gWhisperFullGetSegmentTextFromState: function(aState: PWhisperState; aSegmentIndex: LongInt): PChar; cdecl;
  gWhisperFullGetSegmentT0FromState: function(aState: PWhisperState; aSegmentIndex: LongInt): Int64; cdecl;
  gWhisperFullGetSegmentT1FromState: function(aState: PWhisperState; aSegmentIndex: LongInt): Int64; cdecl;
  gWhisperFullGetTokenTextFromState: function(aContext: PWhisperContext; aState: PWhisperState; aSegmentIndex: LongInt; aTokenIndex: LongInt): PChar; cdecl;
  gWhisperFullGetTokenDataFromState: function(aState: PWhisperState; aSegmentIndex: LongInt; aTokenIndex: LongInt): TWhisperTokenData; cdecl;
  gSherpaCreateOfflineSpeakerDiarization: function(aConfig: PTSherpaOnnxOfflineSpeakerDiarizationConfig): Pointer; cdecl;
  gSherpaDestroyOfflineSpeakerDiarization: procedure(aHandle: Pointer); cdecl;
  gSherpaOfflineSpeakerDiarizationGetSampleRate: function(aHandle: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationSetConfig: procedure(aHandle: Pointer; aConfig: PTSherpaOnnxOfflineSpeakerDiarizationConfig); cdecl;
  gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers: function(aResult: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationResultGetNumSegments: function(aResult: Pointer): LongInt; cdecl;
  gSherpaOfflineSpeakerDiarizationResultSortByStartTime: function(aResult: Pointer): PSherpaOnnxOfflineSpeakerDiarizationSegment; cdecl;
  gSherpaOfflineSpeakerDiarizationDestroySegment: procedure(aSegments: Pointer); cdecl;
  gSherpaOfflineSpeakerDiarizationProcess: function(aHandle: Pointer; const aSamples: PSingle; aSampleCount: LongInt): Pointer; cdecl;
  gSherpaOfflineSpeakerDiarizationDestroyResult: procedure(aResult: Pointer); cdecl;

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

function parseGpuDevice(const aValue: string): LongInt;
var
  deviceValue: Int64;
begin
  deviceValue := StrToInt64Def(Trim(aValue), -1);
  if (deviceValue < 0) or (deviceValue > High(LongInt)) then
    raise Exception.CreateFmt('Invalid GPU device: %s', [aValue]);

  Result := LongInt(deviceValue);
end;

function parseBooleanValue(const aName: string; const aValue: string): Boolean;
var
  normalized: string;
begin
  normalized := LowerCase(Trim(aValue));
  if (normalized = '1') or (normalized = 'true') or (normalized = 'yes') or (normalized = 'on') then
    Exit(True);

  if (normalized = '0') or (normalized = 'false') or (normalized = 'no') or (normalized = 'off') then
    Exit(False);

  raise Exception.CreateFmt('Invalid boolean for %s: %s', [aName, aValue]);
end;

function readEnvBoolean(const aName: string; aDefault: Boolean): Boolean;
var
  value: string;
begin
  value := Trim(SysUtils.GetEnvironmentVariable(aName));
  if value = '' then
    Exit(aDefault);

  Result := parseBooleanValue(aName, value);
end;

function readEnvGpuDevice(const aName: string; aDefault: LongInt): LongInt;
var
  value: string;
begin
  value := Trim(SysUtils.GetEnvironmentVariable(aName));
  if value = '' then
    Exit(aDefault);

  Result := parseGpuDevice(value);
end;

function parseSingleValue(const aName: string; const aValue: string): Single;
var
  fs: TFormatSettings;
  text: string;
  parsed: Double;
begin
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  text := StringReplace(Trim(aValue), ',', '.', [rfReplaceAll]);
  if not TryStrToFloat(text, parsed, fs) then
    raise Exception.CreateFmt('Invalid float for %s: %s', [aName, aValue]);

  Result := parsed;
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

function readEnvFloat(const aName: string; aDefault: Single): Single;
var
  value: string;
begin
  value := Trim(SysUtils.GetEnvironmentVariable(aName));
  if value = '' then
    Exit(aDefault);

  Result := parseSingleValue(aName, value);
end;

procedure writeUsage;
begin
  WriteLn('Usage: ', ExtractFileName(ParamStr(0)), ' [options]');
  WriteLn('  --model-name <value>    model runtime, default whisper_podlodka');
  WriteLn('  --host <value>          listen host, default 127.0.0.1');
  WriteLn('  --port <value>          listen port, default 7801');
  WriteLn('  --gpu                   enable whisper.cpp GPU backend');
  WriteLn('  --no-gpu                force whisper.cpp CPU backend');
  WriteLn('  --gpu-device <value>    GPU device index, default 0');
  WriteLn('  --whisper-dll <path>    explicit whisper.dll path override');
  WriteLn('  --release-tag <value>   whisper.dll release tag under services\whisperdaemon\releases');
  WriteLn('  --sherpa-dll <path>     explicit sherpa-onnx.dll path override');
  WriteLn('  --diarize-seg-model <path>   speaker segmentation ONNX model');
  WriteLn('  --diarize-emb-model <path>   speaker embedding ONNX model');
  WriteLn('  --num-speakers <value>       fixed speaker count, default -1');
  WriteLn('  --cluster-threshold <value>  clustering threshold, default 0.5');
  WriteLn('  --diarize-min-duration-on <value>   diarization min active speech, default 0.2');
  WriteLn('  --diarize-min-duration-off <value>  diarization min silence gap, default 0.5');
  WriteLn('  env: WHISPER_USE_GPU, WHISPER_GPU_DEVICE, WHISPER_DLL_PATH, WHISPER_RELEASE_TAG');
  WriteLn('  env: SHERPA_DLL_PATH, DIARIZE_SEG_MODEL, DIARIZE_EMB_MODEL, DIARIZE_NUM_SPEAKERS, DIARIZE_CLUSTER_THRESHOLD');
end;

function parseCommandLine: TWhisperDaemonOptions;
var
  arg: string;
  val: string;
  idx: Integer;
begin
  Result.Host := '127.0.0.1';
  Result.Port := 7801;
  Result.ModelName := 'whisper_podlodka';
  Result.UseGpu := readEnvBoolean('WHISPER_USE_GPU', False);
  Result.GpuDevice := readEnvGpuDevice('WHISPER_GPU_DEVICE', 0);
  Result.WhisperDllPath := Trim(SysUtils.GetEnvironmentVariable('WHISPER_DLL_PATH'));
  Result.ReleaseTag := Trim(SysUtils.GetEnvironmentVariable('WHISPER_RELEASE_TAG'));
  Result.SherpaDllPath := Trim(SysUtils.GetEnvironmentVariable('SHERPA_DLL_PATH'));
  Result.DiarizeSegModelPath := Trim(SysUtils.GetEnvironmentVariable('DIARIZE_SEG_MODEL'));
  Result.DiarizeEmbModelPath := Trim(SysUtils.GetEnvironmentVariable('DIARIZE_EMB_MODEL'));
  Result.DiarizeNumSpeakers := readEnvInt64('DIARIZE_NUM_SPEAKERS', -1);
  Result.DiarizeClusterThreshold := readEnvFloat('DIARIZE_CLUSTER_THRESHOLD', 0.5);
  Result.DiarizeMinDurationOn := readEnvFloat('DIARIZE_MIN_DURATION_ON', 0.2);
  Result.DiarizeMinDurationOff := readEnvFloat('DIARIZE_MIN_DURATION_OFF', 0.5);
  if Result.ReleaseTag = '' then
    Result.ReleaseTag := '1.8.4';

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
    else if arg = '--gpu' then
      Result.UseGpu := True
    else if arg = '--no-gpu' then
      Result.UseGpu := False
    else if arg = '--gpu-device' then
    begin
      Inc(idx);
      requireArgValue(idx, '--gpu-device', val);
      Result.GpuDevice := parseGpuDevice(val);
      Result.UseGpu := True;
    end
    else if arg = '--whisper-dll' then
    begin
      Inc(idx);
      requireArgValue(idx, '--whisper-dll', val);
      Result.WhisperDllPath := Trim(val);
    end
    else if arg = '--release-tag' then
    begin
      Inc(idx);
      requireArgValue(idx, '--release-tag', val);
      Result.ReleaseTag := Trim(val);
    end
    else if arg = '--sherpa-dll' then
    begin
      Inc(idx);
      requireArgValue(idx, '--sherpa-dll', val);
      Result.SherpaDllPath := Trim(val);
    end
    else if arg = '--diarize-seg-model' then
    begin
      Inc(idx);
      requireArgValue(idx, '--diarize-seg-model', val);
      Result.DiarizeSegModelPath := Trim(val);
    end
    else if arg = '--diarize-emb-model' then
    begin
      Inc(idx);
      requireArgValue(idx, '--diarize-emb-model', val);
      Result.DiarizeEmbModelPath := Trim(val);
    end
    else if arg = '--num-speakers' then
    begin
      Inc(idx);
      requireArgValue(idx, '--num-speakers', val);
      Result.DiarizeNumSpeakers := StrToInt64Def(Trim(val), -1);
    end
    else if arg = '--cluster-threshold' then
    begin
      Inc(idx);
      requireArgValue(idx, '--cluster-threshold', val);
      Result.DiarizeClusterThreshold := parseSingleValue('--cluster-threshold', val);
    end
    else if arg = '--diarize-min-duration-on' then
    begin
      Inc(idx);
      requireArgValue(idx, '--diarize-min-duration-on', val);
      Result.DiarizeMinDurationOn := parseSingleValue('--diarize-min-duration-on', val);
    end
    else if arg = '--diarize-min-duration-off' then
    begin
      Inc(idx);
      requireArgValue(idx, '--diarize-min-duration-off', val);
      Result.DiarizeMinDurationOff := parseSingleValue('--diarize-min-duration-off', val);
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

function resolveWhisperDllPath: string;
var
  releaseTag: string;
begin
  if Trim(gDaemonOptions.WhisperDllPath) <> '' then
    Exit(resolveOptionalPath(gDaemonOptions.WhisperDllPath));

  releaseTag := Trim(gDaemonOptions.ReleaseTag);
  if releaseTag = '' then
    releaseTag := '1.8.4';

  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) +
    'services' + PathDelim + 'whisperdaemon' + PathDelim +
    'releases' + PathDelim + releaseTag + PathDelim + 'whisper.dll';
end;

function resolveSherpaDllPath: string;
begin
  if Trim(gDaemonOptions.SherpaDllPath) <> '' then
    Exit(resolveOptionalPath(gDaemonOptions.SherpaDllPath));

  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) +
    'services' + PathDelim + 'whisperdaemon' + PathDelim +
    'vendors' + PathDelim + 'sherpa-onnx' + PathDelim + 'sherpa-onnx.dll';
end;

function resolveWhisperModelsRoot: string;
begin
  Result := Trim(SysUtils.GetEnvironmentVariable('WHISPER_MODELS_ROOT'));
  if Result = '' then
    Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) + 'services' + PathDelim + 'whisperdaemon' + PathDelim + 'models';
end;

function resolveWhisperModelPath(const aModelName: string): string;
var
  fileName: string;
begin
  if FileExists(aModelName) then
    Exit(ExpandFileName(aModelName));

  fileName := Trim(aModelName);
  if SameText(ExtractFileExt(fileName), '.bin') then
    Result := IncludeTrailingPathDelimiter(resolveWhisperModelsRoot) + fileName
  else
    Result := IncludeTrailingPathDelimiter(resolveWhisperModelsRoot) + 'ggml-' + fileName + '.bin';
end;

procedure ensureDiarizationAssetsAvailable(const aOptions: TWhisperDaemonOptions);
var
  segPath: string;
  embPath: string;
  sherpaPath: string;
begin
  segPath := resolveRequiredPath(
    aOptions.DiarizeSegModelPath,
    'services' + PathDelim + 'whisperdaemon' + PathDelim + 'models' + PathDelim + 'diarization' + PathDelim + 'segmentation.onnx'
  );
  embPath := resolveRequiredPath(
    aOptions.DiarizeEmbModelPath,
    'services' + PathDelim + 'whisperdaemon' + PathDelim + 'models' + PathDelim + 'diarization' + PathDelim + 'embedding.onnx'
  );
  sherpaPath := resolveRequiredPath(
    aOptions.SherpaDllPath,
    'services' + PathDelim + 'whisperdaemon' + PathDelim + 'vendors' + PathDelim + 'sherpa-onnx' + PathDelim + 'sherpa-onnx.dll'
  );

  if not FileExists(segPath) then
    raise Exception.CreateFmt('Required diarization segmentation model not found: %s', [segPath]);
  if not FileExists(embPath) then
    raise Exception.CreateFmt('Required diarization embedding model not found: %s', [embPath]);
  if not FileExists(sherpaPath) then
    raise Exception.CreateFmt('Required sherpa runtime not found: %s', [sherpaPath]);
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
    raise Exception.CreateFmt('Missing export: %s', [aName]);
end;

procedure freeCachedContext;
begin
  if (gCachedContext <> nil) and Assigned(gWhisperFree) then
    gWhisperFree(gCachedContext);

  gCachedContext := nil;
  gCachedModelPath := '';
end;

procedure unloadWhisperLibrary;
begin
  freeCachedContext;

  if gWhisperHandle <> 0 then
    UnloadLibrary(gWhisperHandle);

  gWhisperHandle := 0;
  gWhisperDllPath := '';
  gWhisperLoaded := False;
  Pointer(gWhisperContextDefaultParams) := nil;
  Pointer(gWhisperInitState) := nil;
  Pointer(gWhisperFreeState) := nil;
  Pointer(gWhisperFree) := nil;
  Pointer(gWhisperVersion) := nil;
  Pointer(gWhisperFullDefaultParams) := nil;
  Pointer(gWhisperFullWithState) := nil;
  Pointer(gWhisperFullNSegmentsFromState) := nil;
  Pointer(gWhisperFullNTokensFromState) := nil;
  Pointer(gWhisperInitFromFileWithParamsNoState) := nil;
  Pointer(gWhisperLangStr) := nil;
  Pointer(gWhisperFullLangIdFromState) := nil;
  Pointer(gWhisperFullGetSegmentTextFromState) := nil;
  Pointer(gWhisperFullGetSegmentT0FromState) := nil;
  Pointer(gWhisperFullGetSegmentT1FromState) := nil;
  Pointer(gWhisperFullGetTokenTextFromState) := nil;
  Pointer(gWhisperFullGetTokenDataFromState) := nil;
end;

procedure unloadSherpaLibrary;
begin
  if (gSpeakerDiarizer <> nil) and Assigned(gSherpaDestroyOfflineSpeakerDiarization) then
    gSherpaDestroyOfflineSpeakerDiarization(gSpeakerDiarizer);

  gSpeakerDiarizer := nil;

  if gSherpaHandle <> 0 then
    UnloadLibrary(gSherpaHandle);

  gSherpaHandle := 0;
  gSherpaDllPath := '';
  gSherpaLoaded := False;
  Pointer(gSherpaCreateOfflineSpeakerDiarization) := nil;
  Pointer(gSherpaDestroyOfflineSpeakerDiarization) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationGetSampleRate) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationSetConfig) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultGetNumSegments) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationResultSortByStartTime) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationDestroySegment) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationProcess) := nil;
  Pointer(gSherpaOfflineSpeakerDiarizationDestroyResult) := nil;
end;

procedure loadWhisperLibrary; forward;
function getOrCreateCachedContext(const aModelName: string): PWhisperContext; forward;
function getOrCreateSpeakerDiarizer: Pointer; forward;

constructor TWhisperWarmupThread.Create(const aModelName: string);
begin
  FmodelName := aModelName;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TWhisperWarmupThread.Execute;
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
    loadWhisperLibrary;
    getOrCreateCachedContext(FmodelName);
    gWarmupState := mwsReady;
    WriteLn('[whisperdaemon] warmup ready model=', FmodelName);
  except
    on E: Exception do
    begin
      gWarmupError := E.Message;
      gWarmupState := mwsFailed;
      WriteLn(StdErr, '[whisperdaemon] warmup failed: ', E.Message);
    end;
  end;

  if gWarmupSignal <> nil then
    gWarmupSignal.SetEvent;
end;

procedure loadWhisperLibrary;
var
  dllPath: string;
begin
  dllPath := ExpandFileName(resolveWhisperDllPath);

  if gWhisperLoaded then
  begin
    if SameText(gWhisperDllPath, dllPath) then
      Exit;
    unloadWhisperLibrary;
  end;

  if not FileExists(dllPath) then
    raise Exception.CreateFmt('whisper.dll not found: %s', [dllPath]);

  prependDirectoryToPath(ExtractFileDir(dllPath));
  gWhisperHandle := SafeLoadLibrary(dllPath);
  if gWhisperHandle = 0 then
    raise Exception.CreateFmt('Failed to load whisper.dll from: %s', [dllPath]);

  Pointer(gWhisperContextDefaultParams) := GetProcedureAddress(gWhisperHandle, 'whisper_context_default_params');
  Pointer(gWhisperInitState) := GetProcedureAddress(gWhisperHandle, 'whisper_init_state');
  Pointer(gWhisperFreeState) := GetProcedureAddress(gWhisperHandle, 'whisper_free_state');
  Pointer(gWhisperFree) := GetProcedureAddress(gWhisperHandle, 'whisper_free');
  Pointer(gWhisperVersion) := GetProcedureAddress(gWhisperHandle, 'whisper_version');
  Pointer(gWhisperFullDefaultParams) := GetProcedureAddress(gWhisperHandle, 'whisper_full_default_params');
  Pointer(gWhisperFullWithState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_with_state');
  Pointer(gWhisperFullNSegmentsFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_n_segments_from_state');
  Pointer(gWhisperFullNTokensFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_n_tokens_from_state');
  Pointer(gWhisperInitFromFileWithParamsNoState) := GetProcedureAddress(gWhisperHandle, 'whisper_init_from_file_with_params_no_state');
  Pointer(gWhisperLangStr) := GetProcedureAddress(gWhisperHandle, 'whisper_lang_str');
  Pointer(gWhisperFullLangIdFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_lang_id_from_state');
  Pointer(gWhisperFullGetSegmentTextFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_text_from_state');
  Pointer(gWhisperFullGetSegmentT0FromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_t0_from_state');
  Pointer(gWhisperFullGetSegmentT1FromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_t1_from_state');
  Pointer(gWhisperFullGetTokenTextFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_token_text_from_state');
  Pointer(gWhisperFullGetTokenDataFromState) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_token_data_from_state');

  requireAssigned(Pointer(gWhisperContextDefaultParams), 'whisper_context_default_params');
  requireAssigned(Pointer(gWhisperInitState), 'whisper_init_state');
  requireAssigned(Pointer(gWhisperFreeState), 'whisper_free_state');
  requireAssigned(Pointer(gWhisperFree), 'whisper_free');
  requireAssigned(Pointer(gWhisperVersion), 'whisper_version');
  requireAssigned(Pointer(gWhisperFullDefaultParams), 'whisper_full_default_params');
  requireAssigned(Pointer(gWhisperFullWithState), 'whisper_full_with_state');
  requireAssigned(Pointer(gWhisperFullNSegmentsFromState), 'whisper_full_n_segments_from_state');
  requireAssigned(Pointer(gWhisperFullNTokensFromState), 'whisper_full_n_tokens_from_state');
  requireAssigned(Pointer(gWhisperInitFromFileWithParamsNoState), 'whisper_init_from_file_with_params_no_state');
  requireAssigned(Pointer(gWhisperFullGetSegmentTextFromState), 'whisper_full_get_segment_text_from_state');
  requireAssigned(Pointer(gWhisperFullGetSegmentT0FromState), 'whisper_full_get_segment_t0_from_state');
  requireAssigned(Pointer(gWhisperFullGetSegmentT1FromState), 'whisper_full_get_segment_t1_from_state');
  requireAssigned(Pointer(gWhisperFullGetTokenTextFromState), 'whisper_full_get_token_text_from_state');
  requireAssigned(Pointer(gWhisperFullGetTokenDataFromState), 'whisper_full_get_token_data_from_state');

  gWhisperDllPath := dllPath;
  gWhisperLoaded := True;
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

  prependDirectoryToPath(ExtractFileDir(dllPath));
  gSherpaHandle := SafeLoadLibrary(dllPath);
  if gSherpaHandle = 0 then
    raise Exception.CreateFmt('Failed to load sherpa-onnx.dll from: %s', [dllPath]);

  Pointer(gSherpaCreateOfflineSpeakerDiarization) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxCreateOfflineSpeakerDiarization');
  Pointer(gSherpaDestroyOfflineSpeakerDiarization) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxDestroyOfflineSpeakerDiarization');
  Pointer(gSherpaOfflineSpeakerDiarizationGetSampleRate) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationGetSampleRate');
  Pointer(gSherpaOfflineSpeakerDiarizationSetConfig) := GetProcedureAddress(gSherpaHandle, 'SherpaOnnxOfflineSpeakerDiarizationSetConfig');
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

function getOrCreateSpeakerDiarizer: Pointer;
var
  config: TSherpaOnnxOfflineSpeakerDiarizationConfig;
  embeddingPath: string;
  segmentationPath: string;
begin
  EnterCriticalSection(gSherpaLock);
  try
    loadSherpaLibrary;

    if gSpeakerDiarizer <> nil then
      Exit(gSpeakerDiarizer);

    segmentationPath := resolveOptionalPath(gDaemonOptions.DiarizeSegModelPath);
    embeddingPath := resolveOptionalPath(gDaemonOptions.DiarizeEmbModelPath);
    if segmentationPath = '' then
      raise Exception.Create('DIARIZE_SEG_MODEL is not configured');
    if embeddingPath = '' then
      raise Exception.Create('DIARIZE_EMB_MODEL is not configured');
    if not FileExists(segmentationPath) then
      raise Exception.CreateFmt('Speaker segmentation model not found: %s', [segmentationPath]);
    if not FileExists(embeddingPath) then
      raise Exception.CreateFmt('Speaker embedding model not found: %s', [embeddingPath]);

    FillChar(config, SizeOf(config), 0);
    config.Segmentation.Pyannote.Model := PChar(segmentationPath);
    config.Segmentation.NumThreads := 1;
    config.Embedding.Model := PChar(embeddingPath);
    config.Embedding.NumThreads := 1;
    config.Clustering.NumClusters := gDaemonOptions.DiarizeNumSpeakers;
    config.Clustering.Threshold := gDaemonOptions.DiarizeClusterThreshold;
    config.MinDurationOn := gDaemonOptions.DiarizeMinDurationOn;
    config.MinDurationOff := gDaemonOptions.DiarizeMinDurationOff;

    gSpeakerDiarizer := gSherpaCreateOfflineSpeakerDiarization(@config);
    if gSpeakerDiarizer = nil then
      raise Exception.Create('SherpaOnnxCreateOfflineSpeakerDiarization returned nil');

    Result := gSpeakerDiarizer;
  finally
    LeaveCriticalSection(gSherpaLock);
  end;
end;

function getOrCreateCachedContext(const aModelName: string): PWhisperContext;
var
  modelPath: string;
  params: TWhisperContextParams;
begin
  modelPath := ExpandFileName(resolveWhisperModelPath(aModelName));
  if not FileExists(modelPath) then
    raise Exception.CreateFmt('Whisper model file not found: %s', [modelPath]);

  if (gCachedContext <> nil) and SameText(gCachedModelPath, modelPath) then
    Exit(gCachedContext);

  freeCachedContext;
  params := gWhisperContextDefaultParams();
  params.useGpu := gDaemonOptions.UseGpu;
  params.gpuDevice := gDaemonOptions.GpuDevice;
  gCachedContext := gWhisperInitFromFileWithParamsNoState(PChar(modelPath), params);
  if gCachedContext = nil then
    raise Exception.Create('whisper_init_from_file_with_params_no_state failed');

  gCachedModelPath := modelPath;
  Result := gCachedContext;
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
  WriteLn('[whisperdaemon] warmup started model=', aModelName);
  TWhisperWarmupThread.Create(aModelName);
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

constructor TWhisperDaemonSession.Create(aConnection: TWSConnection; const aModelName: string);
begin
  inherited Create;
  Fmode := 'dictation';
  Fstarted := False;
  Flanguage := 'ru';
  FaudioBytes := nil;
  FresolvedLanguage := '';
  FfinalText := '';
  FmodelName := aModelName;
  FrequestId := '';
  Fconnection := aConnection;
  FsegmentCount := 0;
  FlastAutoCheckBytes := 0;
  FspeakerEmbeddings := False;
  FspeakerCount := 0;
  SetLength(FspeakerSegments, 0);
  SetLength(FfullSessionAudioBytes, 0);
end;

procedure TWhisperDaemonSession.appendAudioBytes(const aBytes: TBytes);
var
  oldLen: SizeInt;
  newLen: SizeInt;
  byteLen: SizeInt;
begin
  byteLen := Length(aBytes);
  if byteLen <= 0 then
    Exit;

  oldLen := Length(FaudioBytes);
  newLen := oldLen + byteLen;
  if newLen > MAX_SESSION_AUDIO_BYTES then
    raise Exception.CreateFmt(
      'Session audio buffer reached %d bytes. Flush more frequently.',
      [MAX_SESSION_AUDIO_BYTES]
    );

  SetLength(FaudioBytes, newLen);
  Move(aBytes[0], FaudioBytes[oldLen], byteLen);
end;

procedure TWhisperDaemonSession.appendFullSessionAudioBytes(const aBytes: TBytes);
var
  oldLen: SizeInt;
  newLen: SizeInt;
  byteLen: SizeInt;
begin
  byteLen := Length(aBytes);
  if byteLen <= 0 then
    Exit;

  oldLen := Length(FfullSessionAudioBytes);
  newLen := oldLen + byteLen;
  if newLen > MAX_SESSION_AUDIO_BYTES then
    raise Exception.CreateFmt(
      'Session audio buffer reached %d bytes. Flush more frequently.',
      [MAX_SESSION_AUDIO_BYTES]
    );

  SetLength(FfullSessionAudioBytes, newLen);
  Move(aBytes[0], FfullSessionAudioBytes[oldLen], byteLen);
end;

procedure TWhisperDaemonSession.appendTextWithSpace(var aTarget: string; const aValue: string);
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

procedure TWhisperDaemonSession.appendWordEvent(
  var aWordEvents: TWhisperWordEvents;
  var aWordEventCount: Integer;
  aSegmentIndex: Integer;
  aIndexInSegment: Integer;
  const aText: string;
  aStartMs: Int64;
  aEndMs: Int64;
  aConfidence: Double
);
var
  growBy: Integer;
begin
  if Trim(aText) = '' then
    Exit;

  if aWordEventCount >= Length(aWordEvents) then
  begin
    growBy := 16;
    if Length(aWordEvents) > 128 then
      growBy := Length(aWordEvents) div 2;
    SetLength(aWordEvents, Length(aWordEvents) + growBy);
  end;

  aWordEvents[aWordEventCount].Text := Trim(aText);
  aWordEvents[aWordEventCount].StartMs := aStartMs;
  aWordEvents[aWordEventCount].EndMs := aEndMs;
  aWordEvents[aWordEventCount].Confidence := aConfidence;
  aWordEvents[aWordEventCount].SegmentIndex := aSegmentIndex;
  aWordEvents[aWordEventCount].IndexInSegment := aIndexInSegment;
  Inc(aWordEventCount);
end;

procedure TWhisperDaemonSession.clearSessionData(aResetSummary: Boolean = True);
begin
  if aResetSummary then
  begin
    FresolvedLanguage := '';
    FfinalText := '';
    FsegmentCount := 0;
    SetLength(FfullSessionAudioBytes, 0);
    clearDiarizationData;
  end;

  FlastAutoCheckBytes := 0;
  SetLength(FaudioBytes, 0);
end;

procedure TWhisperDaemonSession.clearDiarizationData;
begin
  FspeakerCount := 0;
  SetLength(FspeakerSegments, 0);
end;

function TWhisperDaemonSession.findSpeakerForRange(const aTimeline: TSpeakerSegments; aStartMs: Int64; aEndMs: Int64): string;
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

procedure TWhisperDaemonSession.runSpeakerDiarization;
var
  diarizer: Pointer;
  diarizationResult: Pointer;
  diarizationSegments: PSherpaOnnxOfflineSpeakerDiarizationSegment;
  diarizationTimeline: TSpeakerSegments;
  pcm: TFloatArray;
  idx: Integer;
  segmentCount: Integer;
  sampleRate: Integer;
begin
  FspeakerCount := 0;
  for idx := 0 to High(FspeakerSegments) do
    FspeakerSegments[idx].SpeakerId := '';

  if not FspeakerEmbeddings then
    Exit;
  if Length(FspeakerSegments) = 0 then
    Exit;
  if Length(FfullSessionAudioBytes) = 0 then
    Exit;
  if (Trim(gDaemonOptions.DiarizeSegModelPath) = '') or (Trim(gDaemonOptions.DiarizeEmbModelPath) = '') then
  begin
    WriteLn(StdErr, '[whisperdaemon] diarization skipped: DIARIZE_SEG_MODEL/DIARIZE_EMB_MODEL is not configured');
    Exit;
  end;

  try
    diarizer := getOrCreateSpeakerDiarizer;
    pcm := bytesToPcmFloat(FfullSessionAudioBytes);
    if Length(pcm) = 0 then
      Exit;

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
      FspeakerCount := gSherpaOfflineSpeakerDiarizationResultGetNumSpeakers(diarizationResult);
      segmentCount := gSherpaOfflineSpeakerDiarizationResultGetNumSegments(diarizationResult);
      if segmentCount <= 0 then
        Exit;

      SetLength(diarizationTimeline, segmentCount);
      diarizationSegments := gSherpaOfflineSpeakerDiarizationResultSortByStartTime(diarizationResult);
      try
        if diarizationSegments = nil then
          Exit;

        for idx := 0 to segmentCount - 1 do
        begin
          diarizationTimeline[idx].SegmentId := idx;
          diarizationTimeline[idx].StartMs := Round(diarizationSegments[idx].Start * 1000.0);
          diarizationTimeline[idx].EndMs := Round(diarizationSegments[idx].Stop * 1000.0);
          diarizationTimeline[idx].SpeakerId := Format('spk_%d', [diarizationSegments[idx].Speaker]);
          diarizationTimeline[idx].Text := '';
        end;
      finally
        if diarizationSegments <> nil then
          gSherpaOfflineSpeakerDiarizationDestroySegment(diarizationSegments);
      end;

      for idx := 0 to High(FspeakerSegments) do
        FspeakerSegments[idx].SpeakerId := findSpeakerForRange(
          diarizationTimeline,
          FspeakerSegments[idx].StartMs,
          FspeakerSegments[idx].EndMs
        );
    finally
      gSherpaOfflineSpeakerDiarizationDestroyResult(diarizationResult);
    end;
  except
    on E: Exception do
    begin
      FspeakerCount := 0;
      WriteLn(StdErr, '[whisperdaemon] diarization skipped: ', E.Message);
      sendWarning('diarization_failed: ' + Trim(E.Message));
    end;
  end;
end;

function TWhisperDaemonSession.endsWithSentenceBoundary(const aText: string): Boolean;
var
  text: string;
  tail: Char;
begin
  text := Trim(aText);
  if text = '' then
    Exit(False);

  tail := text[Length(text)];
  Result := (tail = '.') or (tail = '!') or (tail = '?') or (tail = ';') or (tail = ':');
end;

function TWhisperDaemonSession.tokenHasLeadingSpace(const aText: string): Boolean;
begin
  Result := False;
  if aText = '' then
    Exit;

  Result := aText[1] <= ' ';
end;

function TWhisperDaemonSession.tokenWithoutLeadingSpaces(const aText: string): string;
var
  idx: Integer;
begin
  idx := 1;
  while (idx <= Length(aText)) and (aText[idx] <= ' ') do
    Inc(idx);
  Result := Copy(aText, idx, MaxInt);
end;

function TWhisperDaemonSession.isSpecialTokenText(const aText: string): Boolean;
var
  text: string;
begin
  text := Trim(aText);
  if text = '' then
    Exit(True);

  Result := (text[1] = '[') or (text[1] = '<');
end;

function TWhisperDaemonSession.isClosingPunctuationToken(const aText: string): Boolean;
var
  text: string;
begin
  text := Trim(aText);
  Result := False;
  if Length(text) <> 1 then
    Exit;

  Result := Pos(text[1], '.,!?;:%)]}') > 0;
end;

function TWhisperDaemonSession.containsCjkCodepoint(const aText: string): Boolean;
var
  b1: Byte;
  b2: Byte;
  b3: Byte;
  idx: Integer;
  codepoint: Integer;
begin
  Result := False;
  idx := 1;
  while idx <= Length(aText) do
  begin
    b1 := Ord(aText[idx]);
    if b1 < $80 then
    begin
      Inc(idx);
      Continue;
    end;

    if (idx + 2 <= Length(aText)) and ((b1 and $F0) = $E0) then
    begin
      b2 := Ord(aText[idx + 1]);
      b3 := Ord(aText[idx + 2]);
      codepoint := ((b1 and $0F) shl 12) or ((b2 and $3F) shl 6) or (b3 and $3F);
      if ((codepoint >= $3400) and (codepoint <= $4DBF)) or
         ((codepoint >= $4E00) and (codepoint <= $9FFF)) or
         ((codepoint >= $3040) and (codepoint <= $30FF)) or
         ((codepoint >= $AC00) and (codepoint <= $D7AF)) then
        Exit(True);
      Inc(idx, 3);
      Continue;
    end;

    Inc(idx);
  end;
end;

procedure TWhisperDaemonSession.collectSegmentWords(
  aContext: PWhisperContext;
  aState: PWhisperState;
  aWhisperSegmentIndex: LongInt;
  aOutputSegmentIndex: Integer;
  var aWordEvents: TWhisperWordEvents;
  var aWordEventCount: Integer
);
var
  lastTokenEndMs: Int64;
  segmentEndMs: Int64;
  segmentStartMs: Int64;
  tokenEndMs: Int64;
  tokenStartMs: Int64;
  wordEndMs: Int64;
  wordStartMs: Int64;
  tokenText: string;
  tokenClean: string;
  wordText: string;
  tokenData: TWhisperTokenData;
  wordProbSum: Double;
  tokenIndex: LongInt;
  tokenCount: LongInt;
  wordIndex: Integer;
  wordTokens: Integer;

  procedure flushWord;
  begin
    if (wordText = '') or (wordTokens <= 0) then
      Exit;

    appendWordEvent(
      aWordEvents,
      aWordEventCount,
      aOutputSegmentIndex,
      wordIndex,
      wordText,
      wordStartMs,
      wordEndMs,
      wordProbSum / wordTokens
    );
    Inc(wordIndex);
    wordText := '';
    wordStartMs := 0;
    wordEndMs := 0;
    wordProbSum := 0;
    wordTokens := 0;
  end;

  procedure appendTokenToWord(const aTokenText: string; aStartMs: Int64; aEndMs: Int64; aProbability: Double);
  begin
    if wordText = '' then
      wordStartMs := aStartMs;
    wordText := wordText + aTokenText;
    wordEndMs := aEndMs;
    wordProbSum := wordProbSum + aProbability;
    Inc(wordTokens);
  end;

  procedure normalizeTokenTiming(const aTokenData: TWhisperTokenData; out aStartMs: Int64; out aEndMs: Int64);
  begin
    aStartMs := aTokenData.t0 * 10;
    aEndMs := aTokenData.t1 * 10;

    if aStartMs < segmentStartMs then
      aStartMs := segmentStartMs;
    if aStartMs < lastTokenEndMs then
      aStartMs := lastTokenEndMs;
    if aStartMs > segmentEndMs then
      aStartMs := segmentEndMs;

    if aEndMs > segmentEndMs then
      aEndMs := segmentEndMs;
    if aEndMs < aStartMs then
      aEndMs := aStartMs;

    if (aEndMs = aStartMs) and (aEndMs < segmentEndMs) then
    begin
      Inc(aEndMs, 10);
      if aEndMs > segmentEndMs then
        aEndMs := segmentEndMs;
    end;

    lastTokenEndMs := aEndMs;
  end;

begin
  tokenCount := gWhisperFullNTokensFromState(aState, aWhisperSegmentIndex);
  segmentStartMs := gWhisperFullGetSegmentT0FromState(aState, aWhisperSegmentIndex) * 10;
  segmentEndMs := gWhisperFullGetSegmentT1FromState(aState, aWhisperSegmentIndex) * 10;
  if segmentEndMs < segmentStartMs then
    segmentEndMs := segmentStartMs;
  wordText := '';
  wordStartMs := 0;
  wordEndMs := 0;
  wordProbSum := 0;
  wordIndex := 0;
  wordTokens := 0;
  lastTokenEndMs := segmentStartMs;

  for tokenIndex := 0 to tokenCount - 1 do
  begin
    tokenText := safeCString(gWhisperFullGetTokenTextFromState(aContext, aState, aWhisperSegmentIndex, tokenIndex));
    tokenData := gWhisperFullGetTokenDataFromState(aState, aWhisperSegmentIndex, tokenIndex);
    if isSpecialTokenText(tokenText) then
      Continue;

    tokenClean := tokenWithoutLeadingSpaces(tokenText);
    if tokenClean = '' then
      Continue;

    normalizeTokenTiming(tokenData, tokenStartMs, tokenEndMs);

    if containsCjkCodepoint(tokenClean) and (not tokenHasLeadingSpace(tokenText)) then
    begin
      flushWord;
      appendWordEvent(
        aWordEvents,
        aWordEventCount,
        aOutputSegmentIndex,
        wordIndex,
        tokenClean,
        tokenStartMs,
        tokenEndMs,
        tokenData.p
      );
      Inc(wordIndex);
      Continue;
    end;

    if isClosingPunctuationToken(tokenClean) and (wordText <> '') then
    begin
      appendTokenToWord(tokenClean, tokenStartMs, tokenEndMs, tokenData.p);
      Continue;
    end;

    if tokenHasLeadingSpace(tokenText) and (wordText <> '') then
      flushWord;

    appendTokenToWord(tokenClean, tokenStartMs, tokenEndMs, tokenData.p);
  end;

  flushWord;
end;

procedure TWhisperDaemonSession.inferBufferedAudio(
  out aBatchText: string;
  out aSegmentTexts: TStringArray;
  out aSegmentT0s: TInt64Array;
  out aSegmentT1s: TInt64Array;
  out aWordEvents: TWhisperWordEvents;
  out aWordEventCount: Integer;
  out aCollectedCount: Integer
);
var
  ack: LongInt;
  ctx: PWhisperContext;
  pcm: TFloatArray;
  text: string;
  inferOk: Boolean;
  safeMode: Boolean;
  state: PWhisperState;
  errorText: string;
  ctxParams: TWhisperFullParams;
  retryNeeded: Boolean;
  threadCount: Integer;
  segmentCount: LongInt;
  segmentIndex: LongInt;
  languageCode: string;
  languageUtf8: UTF8String;
begin
  aBatchText := '';
  aCollectedCount := 0;
  aWordEventCount := 0;
  SetLength(aSegmentTexts, 0);
  SetLength(aSegmentT0s, 0);
  SetLength(aSegmentT1s, 0);
  SetLength(aWordEvents, 0);

  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);

  ensureWarmupReady(FmodelName);
  pcm := bytesToPcmFloat(FaudioBytes);
  if Length(pcm) = 0 then
    Exit;

  EnterCriticalSection(gInferenceLock);
  try
    ctx := getOrCreateCachedContext(FmodelName);
    inferOk := False;
    safeMode := False;
    while not inferOk do
    begin
      retryNeeded := False;
      state := nil;
      try
        state := gWhisperInitState(ctx);
        if state = nil then
          raise Exception.Create('whisper_init_state failed');

        try
          if safeMode then
          begin
            ctxParams := gWhisperFullDefaultParams(WHISPER_SAMPLING_GREEDY);
            threadCount := 1;
          end
          else
          begin
            ctxParams := gWhisperFullDefaultParams(WHISPER_SAMPLING_BEAM_SEARCH);
            threadCount := Min(Integer(TThread.ProcessorCount), 4);
          end;

          ctxParams.nThreads := threadCount;
          ctxParams.translate := False;
          ctxParams.noContext := True;
          ctxParams.noTimestamps := False;
          ctxParams.singleSegment := False;
          ctxParams.printSpecial := False;
          ctxParams.printProgress := False;
          ctxParams.printRealtime := False;
          ctxParams.printTimestamps := False;
          ctxParams.tokenTimestamps := True;

          if Trim(Flanguage) = '' then
            languageUtf8 := 'auto'
          else
            languageUtf8 := UTF8String(Flanguage);
          // Never set detectLanguage=True: that flag means "detect language only, skip transcription"
          // Passing language='auto' is enough for whisper to auto-detect and then transcribe
          ctxParams.detectLanguage := False;
          ctxParams.language := PChar(languageUtf8);

          ack := gWhisperFullWithState(ctx, state, ctxParams, @pcm[0], Length(pcm));
          if ack <> 0 then
            raise Exception.CreateFmt('whisper_full_with_state failed: %d', [ack]);

          if SameText(Flanguage, 'auto') then
            languageCode := resolveDetectedLanguageCode(state)
          else
            languageCode := LowerCase(Trim(Flanguage));
          if languageCode <> '' then
            FresolvedLanguage := languageCode;

          segmentCount := gWhisperFullNSegmentsFromState(state);
          SetLength(aSegmentTexts, segmentCount);
          SetLength(aSegmentT0s, segmentCount);
          SetLength(aSegmentT1s, segmentCount);
          for segmentIndex := 0 to segmentCount - 1 do
          begin
            text := Trim(safeCString(gWhisperFullGetSegmentTextFromState(state, segmentIndex)));
            if text = '' then
              Continue;

            aSegmentTexts[aCollectedCount] := text;
            aSegmentT0s[aCollectedCount] := gWhisperFullGetSegmentT0FromState(state, segmentIndex) * 10;
            aSegmentT1s[aCollectedCount] := gWhisperFullGetSegmentT1FromState(state, segmentIndex) * 10;
            collectSegmentWords(ctx, state, segmentIndex, aCollectedCount, aWordEvents, aWordEventCount);
            appendTextWithSpace(aBatchText, text);
            Inc(aCollectedCount);
          end;

          inferOk := True;
        except
          on E: Exception do
          begin
            errorText := Trim(E.Message);
            if (not safeMode) then
            begin
              safeMode := True;
              retryNeeded := True;
              WriteLn(StdErr, '[whisperdaemon] retrying inference with low-memory parameters after: ', errorText);
            end
            else
            begin
              if errorText = '' then
                errorText := 'unknown whisper inference failure';
              raise Exception.CreateFmt('whisper inference failed after retry: %s', [errorText]);
            end;
          end;
        end;
      finally
        if state <> nil then
          gWhisperFreeState(state);
      end;

      if retryNeeded then
        Continue;
    end;
  finally
    LeaveCriticalSection(gInferenceLock);
  end;
end;

procedure TWhisperDaemonSession.processBufferedAudio(aFinalizeSession: Boolean);
var
  audioMs: Int64;
  batchText: string;
  mappedIdx: Integer;
  shouldCommit: Boolean;
  nextWordEventIndex: Integer;
  segmentIndex: Integer;
  collectedCount: Integer;
  startSegmentId: Integer;
  segmentTexts: TStringArray;
  segmentT0s: TInt64Array;
  segmentT1s: TInt64Array;
  wordEvents: TWhisperWordEvents;
  wordEventCount: Integer;
begin
  audioMs := Round(((Length(FaudioBytes) div SizeOf(SmallInt)) * 1000.0) / 16000.0);
  if Length(FaudioBytes) = 0 then
  begin
    if aFinalizeSession then
      sendSessionFinal(audioMs);
    Exit;
  end;

  inferBufferedAudio(batchText, segmentTexts, segmentT0s, segmentT1s, wordEvents, wordEventCount, collectedCount);
  if aFinalizeSession then
    shouldCommit := True
  else
    shouldCommit := endsWithSentenceBoundary(batchText);

  if not shouldCommit then
    Exit;

  startSegmentId := FsegmentCount;
  nextWordEventIndex := 0;
  for segmentIndex := 0 to collectedCount - 1 do
  begin
    while (nextWordEventIndex < wordEventCount) and
          (wordEvents[nextWordEventIndex].SegmentIndex < segmentIndex) do
      Inc(nextWordEventIndex);

    while (nextWordEventIndex < wordEventCount) and
          (wordEvents[nextWordEventIndex].SegmentIndex = segmentIndex) do
    begin
      sendWordCommitted(
        startSegmentId + segmentIndex,
        wordEvents[nextWordEventIndex].IndexInSegment,
        wordEvents[nextWordEventIndex].Text,
        wordEvents[nextWordEventIndex].StartMs,
        wordEvents[nextWordEventIndex].EndMs,
        wordEvents[nextWordEventIndex].Confidence
      );
      Inc(nextWordEventIndex);
    end;

    sendSegmentFinal(
      startSegmentId + segmentIndex,
      segmentTexts[segmentIndex],
      segmentT0s[segmentIndex],
      segmentT1s[segmentIndex]
    );

    if FspeakerEmbeddings then
    begin
      mappedIdx := Length(FspeakerSegments);
      SetLength(FspeakerSegments, mappedIdx + 1);
      FspeakerSegments[mappedIdx].SegmentId := startSegmentId + segmentIndex;
      FspeakerSegments[mappedIdx].StartMs := segmentT0s[segmentIndex];
      FspeakerSegments[mappedIdx].EndMs := segmentT1s[segmentIndex];
      FspeakerSegments[mappedIdx].SpeakerId := '';
      FspeakerSegments[mappedIdx].Text := segmentTexts[segmentIndex];
    end;
  end;

  appendTextWithSpace(FfinalText, batchText);
  Inc(FsegmentCount, collectedCount);

  if aFinalizeSession then
    runSpeakerDiarization;

  clearSessionData(False);

  if not aFinalizeSession then
  begin
    WriteLn('[whisperdaemon] auto-commit at sentence boundary');
    Exit;
  end;

  WriteLn('[whisperdaemon] session_final text=', FfinalText);
  sendSessionFinal(audioMs);
end;

function TWhisperDaemonSession.bytesToPcmFloat(const aBytes: TBytes): TFloatArray;
var
  pcmValue: SmallInt;
  bytePos: SizeInt;
  samplePos: SizeInt;
  sampleCount: SizeInt;
begin
  sampleCount := Length(aBytes) div SizeOf(SmallInt);
  SetLength(Result, sampleCount);
  bytePos := 0;
  samplePos := 0;
  while samplePos < sampleCount do
  begin
    Move(aBytes[bytePos], pcmValue, SizeOf(SmallInt));
    Result[samplePos] := pcmValue / 32768.0;
    Inc(bytePos, SizeOf(SmallInt));
    Inc(samplePos);
  end;
end;

function TWhisperDaemonSession.jsonIntOf(const aObject: TJSONObject; const aName: string): Integer;
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

function TWhisperDaemonSession.jsonBoolOf(const aObject: TJSONObject; const aName: string): Boolean;
var
  data: TJSONData;
  text: string;
begin
  Result := False;
  if aObject = nil then
    Exit;

  data := aObject.Find(aName);
  if (data = nil) or (data.JSONType = jtNull) then
    Exit;

  if data.JSONType = jtBoolean then
    Exit(data.AsBoolean);

  text := LowerCase(Trim(data.AsString));
  Result := (text = '1') or (text = 'true') or (text = 'yes') or (text = 'on');
end;

function TWhisperDaemonSession.jsonStringOf(const aObject: TJSONObject; const aName: string): string;
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

function TWhisperDaemonSession.resolveDetectedLanguageCode(aState: PWhisperState): string;
var
  langId: LongInt;
begin
  Result := '';
  if (aState = nil) or (not Assigned(gWhisperFullLangIdFromState)) or (not Assigned(gWhisperLangStr)) then
    Exit;

  langId := gWhisperFullLangIdFromState(aState);
  if langId < 0 then
    Exit;

  Result := LowerCase(Trim(safeCString(gWhisperLangStr(langId))));
end;

function TWhisperDaemonSession.safeCString(const aValue: PChar): string;
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

procedure TWhisperDaemonSession.sendError(const aMessage: string);
var
  root: TJSONObject;
begin
  WriteLn(StdErr, '[whisperdaemon] error: ', Trim(aMessage));
  root := TJSONObject.Create;
  try
    root.Add('event', 'error');
    root.Add('message', Trim(aMessage));
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.sendWarning(const aMessage: string);
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'warning');
    root.Add('message', Trim(aMessage));
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.sendEvent(aObject: TJSONObject);
begin
  if (aObject = nil) or (Fconnection = nil) then
    Exit;

  Fconnection.Send(UTF8String(aObject.AsJSON));
end;

procedure TWhisperDaemonSession.sendSegmentFinal(aSegmentId: Integer; const aText: string; aStartMs: Int64; aEndMs: Int64);
var
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'segment_final');
    root.Add('text', aText);
    root.Add('segment_id', aSegmentId);
    root.Add('start_ms', aStartMs);
    root.Add('end_ms', aEndMs);
    root.Add('t0_ms', aStartMs);
    root.Add('t1_ms', aEndMs);
    root.Add('is_progressive', False);
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.sendWordCommitted(aSegmentId: Integer; aWordIndex: Integer; const aText: string; aStartMs: Int64; aEndMs: Int64; aConfidence: Double);
var
  root: TJSONObject;
begin
  if Trim(aText) = '' then
    Exit;

  root := TJSONObject.Create;
  try
    root.Add('event', 'word_committed');
    root.Add('text', Trim(aText));
    root.Add('index_in_segment', aWordIndex);
    root.Add('segment_id', aSegmentId);
    root.Add('start_ms', aStartMs);
    root.Add('end_ms', aEndMs);
    root.Add('confidence', aConfidence);
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.sendSessionFinal(aDurationMs: Int64);
var
  arr: TJSONArray;
  idx: Integer;
  item: TJSONObject;
  root: TJSONObject;
  hasSpeakerIds: Boolean;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'session_final');
    root.Add('text', FfinalText);
    root.Add('duration_ms', aDurationMs);
    root.Add('segment_count', FsegmentCount);
    if FresolvedLanguage <> '' then
      root.Add('language', FresolvedLanguage);
    if SameText(Flanguage, 'auto') and (FresolvedLanguage <> '') then
      root.Add('detected_language', FresolvedLanguage);

    hasSpeakerIds := False;
    if FspeakerEmbeddings then
    begin
      for idx := 0 to High(FspeakerSegments) do
      begin
        if Trim(FspeakerSegments[idx].SpeakerId) <> '' then
        begin
          hasSpeakerIds := True;
          Break;
        end;
      end;
    end;

    if hasSpeakerIds and (FspeakerCount > 0) then
      root.Add('speaker_count', FspeakerCount);

    if FspeakerEmbeddings and (Length(FspeakerSegments) > 0) then
    begin
      arr := TJSONArray.Create;
      for idx := 0 to High(FspeakerSegments) do
      begin
        if Trim(FspeakerSegments[idx].SpeakerId) = '' then
          Continue;

        item := TJSONObject.Create;
        item.Add('segment_id', FspeakerSegments[idx].SegmentId);
        item.Add('start_ms', FspeakerSegments[idx].StartMs);
        item.Add('end_ms', FspeakerSegments[idx].EndMs);
        if FspeakerSegments[idx].SpeakerId <> '' then
          item.Add('speaker_id', FspeakerSegments[idx].SpeakerId);
        if FspeakerSegments[idx].Text <> '' then
          item.Add('text', FspeakerSegments[idx].Text);
        arr.Add(item);
      end;

      if arr.Count > 0 then
        root.Add('speaker_segments', arr)
      else
        arr.Free;
    end;
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.handleBinary(const aBytes: TBytes);
begin
  if not Fstarted then
  begin
    sendError('audio_chunk received before session_start');
    Exit;
  end;

  appendAudioBytes(aBytes);
  appendFullSessionAudioBytes(aBytes);
  if Length(FaudioBytes) < AUTO_FLUSH_MIN_BYTES then
    Exit;
  if Length(FaudioBytes) < (FlastAutoCheckBytes + AUTO_FLUSH_STEP_BYTES) then
    Exit;

  FlastAutoCheckBytes := Length(FaudioBytes);
  processBufferedAudio(False);
end;

procedure TWhisperDaemonSession.handleFlush;
begin
  WriteLn('[whisperdaemon] flush received');
  if not Fstarted then
  begin
    sendError('flush received before session_start');
    Exit;
  end;

  try
    processBufferedAudio(True);
  finally
    Fstarted := False;
    clearSessionData(True);
  end;
end;

procedure TWhisperDaemonSession.handleSessionStart(const aRoot: TJSONObject);
var
  ack: TJSONObject;
  channels: Integer;
  sampleRate: Integer;
  sampleFormat: string;
begin
  if Fstarted then
  begin
    sendError('session already started');
    Exit;
  end;

  WriteLn('[whisperdaemon] session_start model=', FmodelName);

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
  Flanguage := jsonStringOf(aRoot, 'language');
  Fmode := jsonStringOf(aRoot, 'mode');
  FrequestId := jsonStringOf(aRoot, 'request_id');
  FspeakerEmbeddings := jsonBoolOf(aRoot, 'speaker_embeddings');
  if Trim(Flanguage) = '' then
    Flanguage := 'ru';
  if Trim(Fmode) = '' then
    Fmode := 'dictation';
  Fstarted := True;

  ack := TJSONObject.Create;
  try
    ack.Add('event', 'session_ack');
    ack.Add('model_name', FmodelName);
    ack.Add('language', Flanguage);
    ack.Add('mode', Fmode);
    ack.Add('connection_id', Fconnection.ConnectionID);
    if FrequestId <> '' then
      ack.Add('request_id', FrequestId);
    sendEvent(ack);
  finally
    ack.Free;
  end;
end;

procedure TWhisperDaemonSession.handleMessage(const aMessage: TWSMessage);
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
    if eventName = 'session_start' then
      handleSessionStart(root)
    else if eventName = 'flush' then
      handleFlush
    else if eventName = 'cancel' then
    begin
      if not Fstarted then
        Exit;
      Fstarted := False;
      sendSessionFinal(0);
      clearSessionData;
    end
    else
      raise Exception.CreateFmt('Unsupported websocket event: %s', [eventName]);
  finally
    data.Free;
  end;
end;

constructor TWhisperDaemonHost.Create(const aOptions: TWhisperDaemonOptions);
begin
  inherited Create(nil);
  FmodelName := aOptions.ModelName;
  Fserver := TWebSocketServer.Create(Self);
  Fserver.Host := aOptions.Host;
  Fserver.Port := aOptions.Port;
  Fserver.ThreadMode := wtmThread;
  Fserver.ThreadedAccept := True;
  Fserver.OnMessageReceived := @handleMessage;
  Fserver.OnDisconnect := @handleDisconnect;
  Fserver.Active := True;
  startWarmup(FmodelName);
end;

destructor TWhisperDaemonHost.Destroy;
begin
  Fserver.Free;
  inherited Destroy;
end;

procedure TWhisperDaemonHost.handleDisconnect(Sender: TObject);
begin
end;

procedure TWhisperDaemonHost.handleMessage(Sender: TObject; const aMessage: TWSMessage);
var
  session: TWhisperDaemonSession;
  connection: TWSConnection;
begin
  connection := TWSConnection(Sender);
  if connection.UserData = nil then
  begin
    connection.UserData := TWhisperDaemonSession.Create(connection, FmodelName);
    connection.FreeUserData := True;
  end;

  session := TWhisperDaemonSession(connection.UserData);
  try
    session.handleMessage(aMessage);
  except
    on E: Exception do
    begin
      WriteLn(StdErr, '[whisperdaemon] exception: ', E.Message);
      session.sendError(E.Message);
      raise;
    end;
  end;
end;

var
  host: TWhisperDaemonHost;
  options: TWhisperDaemonOptions;

begin
  host := nil;
  try
    InitCriticalSection(gInferenceLock);
    InitCriticalSection(gSherpaLock);
    options := parseCommandLine;
    ensureDiarizationAssetsAvailable(options);
    gDaemonOptions := options;
    host := TWhisperDaemonHost.Create(options);
    WriteLn('WhisperDaemon listening on ws://', options.Host, ':', options.Port, '/ model=', options.ModelName);
    WriteLn('[whisperdaemon] gpu=', Ord(options.UseGpu), ' device=', options.GpuDevice, ' release=', options.ReleaseTag);
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
  DoneCriticalSection(gInferenceLock);
  DoneCriticalSection(gSherpaLock);
  gWarmupSignal.Free;
end.