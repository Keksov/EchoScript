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
    RegistryDir: string;
  end;

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
    FautoFlush               : Boolean;
    FaudioBytes              : TBytes;
    Flanguage                : string;
    FresolvedLanguage        : string;
    FfinalText               : string;
    FmodelName               : string;
    FrequestId               : string;
    Fconnection              : TWSConnection;
    FsegmentCount            : Integer;
    FlastAutoCheckBytes      : SizeInt;
    FcommittedMs             : Int64;
    FlastKeepaliveTick       : QWord;
    procedure   onInferenceProgress(aProgress: LongInt);
    procedure   appendAudioBytes(const aBytes: TBytes);
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
    procedure   collectSegmentWords(
                  aContext: PWhisperContext;
                  aWhisperSegmentIndex: LongInt;
                  aOutputSegmentIndex: Integer;
                  var aWordEvents: TWhisperWordEvents;
                  var aWordEventCount: Integer
                );
    procedure   inferPcm16le(const aAudioBytes: TBytes;
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
    procedure   handleDescribe;
    procedure   handleHealth;
    procedure   handleTranscribeFile(const aRoot: TJSONObject);
    function    endsWithSentenceBoundary(const aText: string): Boolean;
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
    function    resolveDetectedLanguageCode(aContext: PWhisperContext): string;
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
  gWarmupState: TModelWarmupState = mwsNotStarted;
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
  // Context (ctx->state) API — used so params.vad takes effect: whisper.cpp applies VAD
  // (and remaps timestamps) only inside whisper_full, not whisper_full_with_state (WR-D6).
  gWhisperInitFromFileWithParams: function(const aPathModel: PChar; var aParams: TWhisperContextParams): PWhisperContext; cdecl;
  gWhisperFull: function(aContext: PWhisperContext; var aParams: TWhisperFullParams; const aSamples: PSingle; aSampleCount: LongInt): LongInt; cdecl;
  gWhisperFullNSegments: function(aContext: PWhisperContext): LongInt; cdecl;
  gWhisperFullNTokens: function(aContext: PWhisperContext; aSegmentIndex: LongInt): LongInt; cdecl;
  gWhisperFullLangId: function(aContext: PWhisperContext): LongInt; cdecl;
  gWhisperFullGetSegmentText: function(aContext: PWhisperContext; aSegmentIndex: LongInt): PChar; cdecl;
  gWhisperFullGetSegmentT0: function(aContext: PWhisperContext; aSegmentIndex: LongInt): Int64; cdecl;
  gWhisperFullGetSegmentT1: function(aContext: PWhisperContext; aSegmentIndex: LongInt): Int64; cdecl;
  gWhisperFullGetTokenText: function(aContext: PWhisperContext; aSegmentIndex: LongInt; aTokenIndex: LongInt): PChar; cdecl;
  gWhisperFullGetTokenData: function(aContext: PWhisperContext; aSegmentIndex: LongInt; aTokenIndex: LongInt): TWhisperTokenData; cdecl;

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
  WriteLn('  --registry-dir <path>   jobs/registry dir for self-registration (default <root>\jobs\registry)');
  WriteLn('  env: WHISPER_USE_GPU, WHISPER_GPU_DEVICE, WHISPER_DLL_PATH, WHISPER_RELEASE_TAG, ECHOSCRIPT_REGISTRY_DIR');
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
  if Result.ReleaseTag = '' then
    Result.ReleaseTag := '1.8.4';
  Result.RegistryDir := Trim(SysUtils.GetEnvironmentVariable('ECHOSCRIPT_REGISTRY_DIR'));

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
    else if arg = '--registry-dir' then
    begin
      Inc(idx);
      requireArgValue(idx, '--registry-dir', val);
      Result.RegistryDir := Trim(val);
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

function resolveVadModelPath: string;
begin
  Result := IncludeTrailingPathDelimiter(resolveWhisperModelsRoot) + 'ggml-silero-v5.1.2.bin';
end;

// VAD is enabled when the Silero model is staged and not force-disabled via WHISPER_VAD=0.
// Removing non-speech before inference is the fix for whisper's repetition loop on
// music/silence (WR-D5); if the model is missing we degrade gracefully (VAD off).
function vadModelAvailable: Boolean;
begin
  if SameText(Trim(SysUtils.GetEnvironmentVariable('WHISPER_VAD')), '0') then
    Exit(False);
  Result := FileExists(resolveVadModelPath);
end;

// Tunable VAD/decode params come from env (set by the control panel from config.json at
// launch, CP4.1); each falls back to the conservative default when unset. Floats parse
// with a '.' separator regardless of locale (see PASCAL_RULES.md §7).
function whisperEnvFloat(const aName: string; aDefault: Single): Single;
var
  raw: string;
  fs: TFormatSettings;
begin
  raw := Trim(SysUtils.GetEnvironmentVariable(aName));
  if raw = '' then
    Exit(aDefault);
  fs := DefaultFormatSettings;
  fs.DecimalSeparator := '.';
  Result := StrToFloatDef(raw, aDefault, fs);
end;

function whisperEnvInt(const aName: string; aDefault: LongInt): LongInt;
var
  raw: string;
begin
  raw := Trim(SysUtils.GetEnvironmentVariable(aName));
  if raw = '' then
    Exit(aDefault);
  Result := StrToIntDef(raw, aDefault);
end;

function resolveDaemonDescriptorPath: string;
begin
  Result := IncludeTrailingPathDelimiter(getWorkspaceRootDir) +
    'services' + PathDelim + 'whisperdaemon' + PathDelim + 'daemon.json';
end;

function loadTextFileUtf8(const aPath: string): string;
var
  stream: TFileStream;
  raw: RawByteString;
begin
  Result := '';
  stream := TFileStream.Create(aPath, fmOpenRead or fmShareDenyNone);
  try
    if stream.Size > 0 then
    begin
      SetLength(raw, stream.Size);
      stream.ReadBuffer(raw[1], stream.Size);
      SetCodePage(raw, 65001, False);
      Result := raw;
    end;
  finally
    stream.Free;
  end;
end;

function loadBinaryFile(const aPath: string): TBytes;
var
  stream: TFileStream;
begin
  Result := nil;
  stream := TFileStream.Create(aPath, fmOpenRead or fmShareDenyNone);
  try
    SetLength(Result, stream.Size);
    if stream.Size > 0 then
      stream.ReadBuffer(Result[0], stream.Size);
  finally
    stream.Free;
  end;
end;

function ptrToHex(const aPtr: Pointer): string;
begin
  Result := '$' + IntToHex(QWord(PtrUInt(aPtr)), SizeOf(Pointer) * 2);
end;

function libHandleToHex(const aHandle: TLibHandle): string;
begin
  Result := '$' + IntToHex(QWord(PtrUInt(aHandle)), SizeOf(Pointer) * 2);
end;

procedure logWarmupDiag(const aStage: string; const aDetails: string = '');
begin
  if aDetails = '' then
    WriteLn(StdErr, '[whisperdaemon][diag] ', aStage)
  else
    WriteLn(StdErr, '[whisperdaemon][diag] ', aStage, ' ', aDetails);
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
  Pointer(gWhisperInitFromFileWithParams) := nil;
  Pointer(gWhisperFull) := nil;
  Pointer(gWhisperFullNSegments) := nil;
  Pointer(gWhisperFullNTokens) := nil;
  Pointer(gWhisperFullLangId) := nil;
  Pointer(gWhisperFullGetSegmentText) := nil;
  Pointer(gWhisperFullGetSegmentT0) := nil;
  Pointer(gWhisperFullGetSegmentT1) := nil;
  Pointer(gWhisperFullGetTokenText) := nil;
  Pointer(gWhisperFullGetTokenData) := nil;
end;

procedure loadWhisperLibrary; forward;
function getOrCreateCachedContext(const aModelName: string): PWhisperContext; forward;

constructor TWhisperWarmupThread.Create(const aModelName: string);
begin
  FmodelName := aModelName;
  FreeOnTerminate := True;
  inherited Create(False);
end;

procedure TWhisperWarmupThread.Execute;
begin
  try
    logWarmupDiag('warmup.enter', 'model=' + FmodelName);
    SetExceptionMask([
      exInvalidOp,
      exDenormalized,
      exZeroDivide,
      exOverflow,
      exUnderflow,
      exPrecision
    ]);

    logWarmupDiag('warmup.step', 'loadWhisperLibrary.begin');
    loadWhisperLibrary;
    logWarmupDiag('warmup.step', 'loadWhisperLibrary.ok');

    logWarmupDiag('warmup.step', 'getOrCreateCachedContext.begin');
    getOrCreateCachedContext(FmodelName);
    logWarmupDiag('warmup.step', 'getOrCreateCachedContext.ok');

    gWarmupState := mwsReady;
    WriteLn('[whisperdaemon] warmup ready model=', FmodelName);
  except
    on E: Exception do
    begin
      logWarmupDiag('warmup.exception.class', E.ClassName);
      logWarmupDiag('warmup.exception.message', E.Message);
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
  versionText: string;
begin
  dllPath := ExpandFileName(resolveWhisperDllPath);
  logWarmupDiag('library.path', dllPath);

  if gWhisperLoaded then
  begin
    if SameText(gWhisperDllPath, dllPath) then
    begin
      logWarmupDiag('library.reuse', gWhisperDllPath);
      Exit;
    end;

    logWarmupDiag('library.reload', gWhisperDllPath + ' -> ' + dllPath);
    unloadWhisperLibrary;
  end;

  if not FileExists(dllPath) then
    raise Exception.CreateFmt('whisper.dll not found: %s', [dllPath]);

  logWarmupDiag('library.load.begin', dllPath);
  prependDirectoryToPath(ExtractFileDir(dllPath));
  gWhisperHandle := SafeLoadLibrary(dllPath);
  if gWhisperHandle = 0 then
    raise Exception.CreateFmt('Failed to load whisper.dll from: %s', [dllPath]);
  logWarmupDiag('library.load.handle', libHandleToHex(gWhisperHandle));

  logWarmupDiag('library.exports.begin');

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
  Pointer(gWhisperInitFromFileWithParams) := GetProcedureAddress(gWhisperHandle, 'whisper_init_from_file_with_params');
  Pointer(gWhisperFull) := GetProcedureAddress(gWhisperHandle, 'whisper_full');
  Pointer(gWhisperFullNSegments) := GetProcedureAddress(gWhisperHandle, 'whisper_full_n_segments');
  Pointer(gWhisperFullNTokens) := GetProcedureAddress(gWhisperHandle, 'whisper_full_n_tokens');
  Pointer(gWhisperFullLangId) := GetProcedureAddress(gWhisperHandle, 'whisper_full_lang_id');
  Pointer(gWhisperFullGetSegmentText) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_text');
  Pointer(gWhisperFullGetSegmentT0) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_t0');
  Pointer(gWhisperFullGetSegmentT1) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_segment_t1');
  Pointer(gWhisperFullGetTokenText) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_token_text');
  Pointer(gWhisperFullGetTokenData) := GetProcedureAddress(gWhisperHandle, 'whisper_full_get_token_data');

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
  requireAssigned(Pointer(gWhisperInitFromFileWithParams), 'whisper_init_from_file_with_params');
  requireAssigned(Pointer(gWhisperFull), 'whisper_full');
  requireAssigned(Pointer(gWhisperFullNSegments), 'whisper_full_n_segments');
  requireAssigned(Pointer(gWhisperFullNTokens), 'whisper_full_n_tokens');
  requireAssigned(Pointer(gWhisperFullLangId), 'whisper_full_lang_id');
  requireAssigned(Pointer(gWhisperFullGetSegmentText), 'whisper_full_get_segment_text');
  requireAssigned(Pointer(gWhisperFullGetSegmentT0), 'whisper_full_get_segment_t0');
  requireAssigned(Pointer(gWhisperFullGetSegmentT1), 'whisper_full_get_segment_t1');
  requireAssigned(Pointer(gWhisperFullGetTokenText), 'whisper_full_get_token_text');
  requireAssigned(Pointer(gWhisperFullGetTokenData), 'whisper_full_get_token_data');

  versionText := '<unknown>';
  if Assigned(gWhisperVersion) then
  begin
    try
      versionText := string(gWhisperVersion());
    except
      on E: Exception do
        versionText := '<error reading version: ' + E.Message + '>';
    end;
  end;
  logWarmupDiag('library.version', versionText);
  logWarmupDiag('library.exports.ok');

  gWhisperDllPath := dllPath;
  gWhisperLoaded := True;
  logWarmupDiag('library.ready', dllPath);
end;

function getOrCreateCachedContext(const aModelName: string): PWhisperContext;
var
  params: TWhisperContextParams;
  initError: string;
  modelPath: string;
  modelSize: Int64;
  retryParams: TWhisperContextParams;
begin
  modelPath := ExpandFileName(resolveWhisperModelPath(aModelName));
  logWarmupDiag('context.model.path', modelPath);

  if not FileExists(modelPath) then
    raise Exception.CreateFmt('Whisper model file not found: %s', [modelPath]);

  if (gCachedContext <> nil) and SameText(gCachedModelPath, modelPath) then
  begin
    logWarmupDiag('context.cache.hit', modelPath);
    Exit(gCachedContext);
  end;

  modelSize := -1;
  try
    with TFileStream.Create(modelPath, fmOpenRead or fmShareDenyNone) do
    try
      modelSize := Size;
    finally
      Free;
    end;
  except
    on E: Exception do
      logWarmupDiag('context.model.size_error', E.Message);
  end;

  if modelSize >= 0 then
    logWarmupDiag('context.model.size', IntToStr(modelSize));

  logWarmupDiag('context.cache.reset');
  freeCachedContext;

  logWarmupDiag('context.params.default.begin');
  params := gWhisperContextDefaultParams();
  logWarmupDiag(
    'context.params.default',
    Format('useGpu=%d flashAttn=%d gpuDevice=%d dtw=%d', [
      Ord(params.useGpu),
      Ord(params.flashAttn),
      params.gpuDevice,
      Ord(params.dtwTokenTimestamps)
    ])
  );

  params.useGpu := gDaemonOptions.UseGpu;
  params.gpuDevice := gDaemonOptions.GpuDevice;

  if not params.useGpu then
  begin
    if params.flashAttn then
    begin
      params.flashAttn := False;
      logWarmupDiag('context.params.adjust', 'flashAttn forced to 0 for CPU mode');
    end;
  end;

  logWarmupDiag(
    'context.params.requested',
    Format('useGpu=%d flashAttn=%d gpuDevice=%d dtw=%d', [
      Ord(params.useGpu),
      Ord(params.flashAttn),
      params.gpuDevice,
      Ord(params.dtwTokenTimestamps)
    ])
  );

  logWarmupDiag('context.init.begin', modelPath);
  initError := '';
  gCachedContext := nil;
  try
    gCachedContext := gWhisperInitFromFileWithParams(PChar(modelPath), params);
  except
    on E: Exception do
    begin
      initError := E.ClassName + ': ' + E.Message;
      logWarmupDiag('context.init.exception', initError);
      gCachedContext := nil;
    end;
  end;

  logWarmupDiag('context.init.result', ptrToHex(gCachedContext));

  if (gCachedContext = nil) and (not params.useGpu) and params.flashAttn then
  begin
    retryParams := params;
    retryParams.flashAttn := False;
    logWarmupDiag(
      'context.init.retry',
      Format('useGpu=%d flashAttn=%d gpuDevice=%d dtw=%d', [
        Ord(retryParams.useGpu),
        Ord(retryParams.flashAttn),
        retryParams.gpuDevice,
        Ord(retryParams.dtwTokenTimestamps)
      ])
    );

    initError := '';
    try
      gCachedContext := gWhisperInitFromFileWithParams(PChar(modelPath), retryParams);
    except
      on E: Exception do
      begin
        initError := E.ClassName + ': ' + E.Message;
        logWarmupDiag('context.init.retry_exception', initError);
        gCachedContext := nil;
      end;
    end;

    logWarmupDiag('context.init.retry_result', ptrToHex(gCachedContext));
  end;

  if gCachedContext = nil then
  begin
    if initError <> '' then
      raise Exception.Create('whisper_init_from_file_with_params_no_state failed: ' + initError);
    raise Exception.Create('whisper_init_from_file_with_params_no_state failed');
  end;

  gCachedModelPath := modelPath;
  logWarmupDiag('context.cache.store', gCachedModelPath);
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
  FautoFlush := True;
  Flanguage := 'ru';
  FaudioBytes := nil;
  FresolvedLanguage := '';
  FfinalText := '';
  FmodelName := aModelName;
  FrequestId := '';
  Fconnection := aConnection;
  FsegmentCount := 0;
  FlastAutoCheckBytes := 0;
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
    FcommittedMs := 0;
  end;

  FlastAutoCheckBytes := 0;
  SetLength(FaudioBytes, 0);
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
  tokenCount := gWhisperFullNTokens(aContext, aWhisperSegmentIndex);
  segmentStartMs := gWhisperFullGetSegmentT0(aContext, aWhisperSegmentIndex) * 10;
  segmentEndMs := gWhisperFullGetSegmentT1(aContext, aWhisperSegmentIndex) * 10;
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
    tokenText := safeCString(gWhisperFullGetTokenText(aContext, aWhisperSegmentIndex, tokenIndex));
    tokenData := gWhisperFullGetTokenData(aContext, aWhisperSegmentIndex, tokenIndex);
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

const
  KEEPALIVE_MIN_INTERVAL_MS = 3000;

{ whisper.cpp progress callback (cdecl): forwarded to the session so it emits `keepalive`
  events during long inference. The orchestrator resets its stream heartbeat on any event,
  so a live-but-silent daemon (sparse speech) is no longer seen as a stall (SR-D2). }
procedure whisperProgressCallback({%H-}aContext: PWhisperContext; {%H-}aState: PWhisperState;
  aProgress: LongInt; aUserData: Pointer); cdecl;
begin
  if aUserData <> nil then
    TWhisperDaemonSession(aUserData).onInferenceProgress(aProgress);
end;

procedure TWhisperDaemonSession.onInferenceProgress(aProgress: LongInt);
var
  tick: QWord;
  ka: TJSONObject;
begin
  tick := GetTickCount64;
  if (FlastKeepaliveTick <> 0) and (tick - FlastKeepaliveTick < KEEPALIVE_MIN_INTERVAL_MS) then
    Exit;
  FlastKeepaliveTick := tick;
  ka := TJSONObject.Create;
  try
    ka.Add('event', 'keepalive');
    ka.Add('progress', aProgress);
    { Best-effort (LF-D2): a broken/closing client connection must NOT throw into the
      inference — otherwise the send error (e.g. WSAECONNRESET 10054) is misread by the
      generic inference handler as OOM and triggers a bogus low-memory retry. }
    try
      sendEvent(ka);
    except
      on E: Exception do
        WriteLn('[whisperdaemon] keepalive send skipped: ', E.Message);
    end;
  finally
    ka.Free;
  end;
end;

procedure TWhisperDaemonSession.inferPcm16le(const aAudioBytes: TBytes;
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
  vadEnabled: Boolean;
  vadPathUtf8: UTF8String;
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
  pcm := bytesToPcmFloat(aAudioBytes);
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
      // No explicit state: whisper_full uses the context's own state (ctx->state), which is
      // required for params.vad to take effect (WR-D6). The outer finally is now a no-op.
      state := nil;
      try
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
          ctxParams.progressCallback := @whisperProgressCallback;
          ctxParams.progressCallbackUserData := Self;

          // Voice-activity detection (WR-D5): strip non-speech (music/silence) before
          // transcription so whisper does not loop/hallucinate on it. Disabled in safeMode
          // (the post-failure retry runs a clean fallback). Conservative params: slightly
          // permissive threshold + generous speech padding so quiet real speech is kept.
          vadEnabled := (not safeMode) and vadModelAvailable;
          ctxParams.vad := vadEnabled;
          if vadEnabled then
          begin
            vadPathUtf8 := UTF8String(resolveVadModelPath);
            ctxParams.vadModelPath := PChar(vadPathUtf8);
            ctxParams.vadParams.threshold := whisperEnvFloat('WHISPER_VAD_THRESHOLD', 0.4);
            ctxParams.vadParams.minSpeechDurationMs := whisperEnvInt('WHISPER_VAD_MIN_SPEECH_MS', 100);
            ctxParams.vadParams.minSilenceDurationMs := whisperEnvInt('WHISPER_VAD_MIN_SILENCE_MS', 100);
            ctxParams.vadParams.maxSpeechDurationS := 3600.0;
            ctxParams.vadParams.speechPadMs := whisperEnvInt('WHISPER_VAD_SPEECH_PAD_MS', 200);
            ctxParams.vadParams.samplesOverlap := 0.1;
          end;
          // Decode anti-hallucination thresholds — tunable from config; unset keeps the
          // whisper.cpp default already in ctxParams (CP4.1).
          ctxParams.noSpeechThold := whisperEnvFloat('WHISPER_NO_SPEECH_THOLD', ctxParams.noSpeechThold);
          ctxParams.entropyThold := whisperEnvFloat('WHISPER_ENTROPY_THOLD', ctxParams.entropyThold);
          WriteLn('[whisperdaemon] inference vad=', BoolToStr(vadEnabled, True),
            ' vad_thold=', FormatFloat('0.00', ctxParams.vadParams.threshold),
            ' no_speech=', FormatFloat('0.00', ctxParams.noSpeechThold),
            ' model=', FmodelName);

          FlastKeepaliveTick := 0;

          // whisper_full (not _with_state): applies params.vad (strips non-speech and remaps
          // timestamps for us) and writes results into the context's own state (WR-D6).
          ack := gWhisperFull(ctx, ctxParams, @pcm[0], Length(pcm));
          if ack <> 0 then
            raise Exception.CreateFmt('whisper_full failed: %d', [ack]);

          if SameText(Flanguage, 'auto') then
            languageCode := resolveDetectedLanguageCode(ctx)
          else
            languageCode := LowerCase(Trim(Flanguage));
          if languageCode <> '' then
            FresolvedLanguage := languageCode;

          segmentCount := gWhisperFullNSegments(ctx);
          SetLength(aSegmentTexts, segmentCount);
          SetLength(aSegmentT0s, segmentCount);
          SetLength(aSegmentT1s, segmentCount);
          for segmentIndex := 0 to segmentCount - 1 do
          begin
            text := Trim(safeCString(gWhisperFullGetSegmentText(ctx, segmentIndex)));
            if text = '' then
              Continue;

            aSegmentTexts[aCollectedCount] := text;
            aSegmentT0s[aCollectedCount] := gWhisperFullGetSegmentT0(ctx, segmentIndex) * 10;
            aSegmentT1s[aCollectedCount] := gWhisperFullGetSegmentT1(ctx, segmentIndex) * 10;
            collectSegmentWords(ctx, segmentIndex, aCollectedCount, aWordEvents, aWordEventCount);
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
      sendSessionFinal(FcommittedMs);
    Exit;
  end;

  inferPcm16le(FaudioBytes, batchText, segmentTexts, segmentT0s, segmentT1s, wordEvents, wordEventCount, collectedCount);
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
        wordEvents[nextWordEventIndex].StartMs + FcommittedMs,
        wordEvents[nextWordEventIndex].EndMs + FcommittedMs,
        wordEvents[nextWordEventIndex].Confidence
      );
      Inc(nextWordEventIndex);
    end;

    { Segment/word times from inferPcm16le are relative to the current buffer,
      which is cleared on every commit. Add FcommittedMs so streamed timestamps
      stay absolute across the whole session (file bridge relies on this). }
    sendSegmentFinal(
      startSegmentId + segmentIndex,
      segmentTexts[segmentIndex],
      segmentT0s[segmentIndex] + FcommittedMs,
      segmentT1s[segmentIndex] + FcommittedMs
    );
  end;

  appendTextWithSpace(FfinalText, batchText);
  Inc(FsegmentCount, collectedCount);

  clearSessionData(False);
  Inc(FcommittedMs, audioMs);

  if not aFinalizeSession then
  begin
    WriteLn('[whisperdaemon] auto-commit at sentence boundary');
    Exit;
  end;

  WriteLn('[whisperdaemon] session_final text=', FfinalText);
  sendSessionFinal(FcommittedMs);
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

function TWhisperDaemonSession.resolveDetectedLanguageCode(aContext: PWhisperContext): string;
var
  langId: LongInt;
begin
  Result := '';
  if (aContext = nil) or (not Assigned(gWhisperFullLangId)) or (not Assigned(gWhisperLangStr)) then
    Exit;

  langId := gWhisperFullLangId(aContext);
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
  root: TJSONObject;
begin
  root := TJSONObject.Create;
  try
    root.Add('event', 'session_final');
    root.Add('text', FfinalText);
    root.Add('duration_ms', aDurationMs);
    root.Add('segment_count', FsegmentCount);
    if FrequestId <> '' then
      root.Add('request_id', FrequestId);
    if FresolvedLanguage <> '' then
      root.Add('language', FresolvedLanguage);
    if SameText(Flanguage, 'auto') and (FresolvedLanguage <> '') then
      root.Add('detected_language', FresolvedLanguage);
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
  { Buffered mode: just accumulate; the whole chunk is inferred once on flush. }
  if not FautoFlush then
    Exit;
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

procedure TWhisperDaemonSession.handleDescribe;
var
  descriptorPath: string;
  descriptor: TJSONData;
  root: TJSONObject;
  transport: TJSONData;
begin
  descriptorPath := resolveDaemonDescriptorPath;
  if not FileExists(descriptorPath) then
  begin
    sendError('daemon descriptor not found: ' + descriptorPath);
    Exit;
  end;

  descriptor := GetJSON(loadTextFileUtf8(descriptorPath));
  try
    if descriptor.JSONType <> jtObject then
    begin
      sendError('daemon descriptor is not a JSON object');
      Exit;
    end;

    root := TJSONObject(descriptor);
    transport := root.Find('transport');
    if (transport <> nil) and (transport.JSONType = jtObject) then
    begin
      TJSONObject(transport).Strings['host'] := gDaemonOptions.Host;
      TJSONObject(transport).Integers['port'] := gDaemonOptions.Port;
    end;
    root.Add('event', 'describe_ack');
    sendEvent(root);
  finally
    descriptor.Free;
  end;
end;

procedure TWhisperDaemonSession.handleHealth;
var
  root: TJSONObject;
  stateText: string;
begin
  case gWarmupState of
    mwsReady: stateText := 'ready';
    mwsFailed: stateText := 'failed';
  else
    stateText := 'loading';
  end;

  root := TJSONObject.Create;
  try
    root.Add('event', 'health_ack');
    root.Add('state', stateText);
    root.Add('model_name', FmodelName);
    if (gWarmupState = mwsFailed) and (gWarmupError <> '') then
      root.Add('error', gWarmupError);
    sendEvent(root);
  finally
    root.Free;
  end;
end;

procedure TWhisperDaemonSession.handleTranscribeFile(const aRoot: TJSONObject);
var
  filePath: string;
  requestId: string;
  language: string;
  params: TJSONData;
begin
  filePath := Trim(jsonStringOf(aRoot, 'path'));
  requestId := jsonStringOf(aRoot, 'request_id');
  language := Trim(jsonStringOf(aRoot, 'language'));

  if filePath = '' then
  begin
    sendError('transcribe_file requires a non-empty path');
    Exit;
  end;

  if not FileExists(filePath) then
  begin
    sendError('transcribe_file: file not found: ' + filePath);
    Exit;
  end;

  clearSessionData(True);
  FrequestId := requestId;
  if language = '' then
    Flanguage := 'ru'
  else
    Flanguage := language;
  Fmode := 'dictation';
  params := aRoot.Find('params');
  if (params <> nil) and (params.JSONType = jtObject) then
    if Trim(jsonStringOf(TJSONObject(params), 'mode')) <> '' then
      Fmode := Trim(jsonStringOf(TJSONObject(params), 'mode'));

  WriteLn('[whisperdaemon] transcribe_file path=', filePath, ' language=', Flanguage);
  try
    FaudioBytes := loadBinaryFile(filePath);
    processBufferedAudio(True);
  except
    on E: Exception do
      sendError('transcribe_file failed: ' + E.Message);
  end;

  clearSessionData(True);
  FrequestId := '';
end;

procedure TWhisperDaemonSession.handleSessionStart(const aRoot: TJSONObject);
var
  ack: TJSONObject;
  channels: Integer;
  sampleRate: Integer;
  sampleFormat: string;
  autoFlushNode: TJSONData;
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
  if Trim(Flanguage) = '' then
    Flanguage := 'ru';
  if Trim(Fmode) = '' then
    Fmode := 'dictation';
  { Buffered mode (LF perf): when the client sets auto_flush=false (file streaming),
    skip per-chunk re-inference and infer once on explicit flush — avoids O(n^2)
    re-inference of a growing buffer on sparse-speech audio. Default true (live). }
  FautoFlush := True;
  autoFlushNode := aRoot.Find('auto_flush');
  if (autoFlushNode <> nil) and (autoFlushNode.JSONType = jtBoolean) and (not autoFlushNode.AsBoolean) then
    FautoFlush := False;
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
    else if eventName = 'describe' then
      handleDescribe
    else if eventName = 'health' then
      handleHealth
    else if eventName = 'transcribe_file' then
      handleTranscribeFile(root)
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

const
  REGISTRY_HEARTBEAT_MS = 5000;

{ UTC ISO-8601 timestamp (Windows GetSystemTime returns UTC). }
function utcNowIso: string;
var
  st: TSystemTime;
begin
  GetSystemTime(st);
  Result := Format('%.4d-%.2d-%.2dT%.2d:%.2d:%.2d.%.3dZ',
    [st.wYear, st.wMonth, st.wDay, st.wHour, st.wMinute, st.wSecond, st.wMilliseconds]);
end;

function registryFilePath(const aOptions: TWhisperDaemonOptions): string;
begin
  Result := IncludeTrailingPathDelimiter(aOptions.RegistryDir) + aOptions.ModelName + '.json';
end;

{ Self-registration for the orchestrator (jobs-drop-daemon-registry, DR-D5): write
  jobs/registry/<model>.json atomically (temp + MoveFileEx) so the watcher never reads
  a half-written file. Keyed by model name (== registry lookup key). }
procedure writeRegistration(const aOptions: TWhisperDaemonOptions; const aState: string);
var
  root, input: TJSONObject;
  json, finalPath, tempPath: string;
  stream: TStringStream;
begin
  root := TJSONObject.Create;
  try
    root.Add('name', aOptions.ModelName);
    root.Add('host', aOptions.Host);
    root.Add('port', Integer(aOptions.Port));
    root.Add('model_name', aOptions.ModelName);
    root.Add('state', aState);
    root.Add('pid', Int64(GetCurrentProcessId));
    input := TJSONObject.Create;
    input.Add('codec', 'pcm16le');
    input.Add('sample_rate_hz', 16000);
    input.Add('channels', 1);
    root.Add('input', input);
    root.Add('updated_at', utcNowIso);
    json := root.FormatJSON;
  finally
    root.Free;
  end;

  ForceDirectories(aOptions.RegistryDir);
  finalPath := registryFilePath(aOptions);
  tempPath := finalPath + '.' + IntToStr(GetCurrentProcessId) + '.tmp';
  stream := TStringStream.Create(json);
  try
    stream.SaveToFile(tempPath);
  finally
    stream.Free;
  end;
  if not MoveFileEx(PChar(tempPath), PChar(finalPath), MOVEFILE_REPLACE_EXISTING) then
    SysUtils.DeleteFile(tempPath);
end;

procedure removeRegistration(const aOptions: TWhisperDaemonOptions);
begin
  SysUtils.DeleteFile(registryFilePath(aOptions));
end;

var
  host: TWhisperDaemonHost;
  options: TWhisperDaemonOptions;
  lastHeartbeat: QWord;
  heartbeatTick: QWord;

begin
  host := nil;
  try
    InitCriticalSection(gInferenceLock);
    options := parseCommandLine;
    if Trim(options.RegistryDir) = '' then
      options.RegistryDir := IncludeTrailingPathDelimiter(getWorkspaceRootDir) + 'jobs' + PathDelim + 'registry';
    gDaemonOptions := options;
    host := TWhisperDaemonHost.Create(options);
    WriteLn('WhisperDaemon listening on ws://', options.Host, ':', options.Port, '/ model=', options.ModelName);
    WriteLn('[whisperdaemon] gpu=', Ord(options.UseGpu), ' device=', options.GpuDevice, ' release=', options.ReleaseTag);
    WriteLn('[whisperdaemon] registry=', options.RegistryDir);
    lastHeartbeat := 0;
    try
      while True do
      begin
        heartbeatTick := GetTickCount64;
        if (lastHeartbeat = 0) or (heartbeatTick - lastHeartbeat >= REGISTRY_HEARTBEAT_MS) then
        begin
          try
            writeRegistration(options, 'ready');
          except
            on E: Exception do
              WriteLn(StdErr, '[whisperdaemon] registry write failed: ', E.Message);
          end;
          lastHeartbeat := heartbeatTick;
        end;
        Sleep(250);
      end;
    finally
      removeRegistration(options);
    end;
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
  gWarmupSignal.Free;
end.