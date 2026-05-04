program WhisperAbiSpike;

{$mode objfpc}{$H+}
{$PACKRECORDS C}

uses
  SysUtils,
  Dynlibs,
  {$ifdef MSWINDOWS}
  Windows,
  {$endif}
  Math;

type
  PWhisperContext = Pointer;
  PWhisperState = Pointer;
  PWhisperToken = ^LongInt;

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
  PWhisperContextParams = ^TWhisperContextParams;

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
  PWhisperFullParams = ^TWhisperFullParams;

const
  WHISPER_SAMPLING_GREEDY = 0;

var
  gWhisperHandle: TLibHandle = 0;
  gWhisperVersion: function(): PChar; cdecl;
  gWhisperFree: procedure(aContext: PWhisperContext); cdecl;
  gWhisperInitState: function(aContext: PWhisperContext): PWhisperState; cdecl;
  gWhisperFreeState: procedure(aState: PWhisperState); cdecl;
  gWhisperFreeParams: procedure(aParams: PWhisperFullParams); cdecl;
  gWhisperFreeContextParams: procedure(aParams: PWhisperContextParams); cdecl;
  gWhisperContextDefaultParams: function(): TWhisperContextParams; cdecl;
  gWhisperContextDefaultParamsByRef: function(): PWhisperContextParams; cdecl;
  gWhisperFullDefaultParams: function(aStrategy: LongInt): TWhisperFullParams; cdecl;
  gWhisperFullDefaultParamsByRef: function(aStrategy: LongInt): PWhisperFullParams; cdecl;
  gWhisperInitFromFileWithParamsNoState: function(const aPathModel: PChar; aParams: TWhisperContextParams): PWhisperContext; cdecl;

function safeCString(const aValue: PChar): string;
begin
  if aValue = nil then
    Exit('');
  Result := string(aValue);
end;

procedure fail(const aMessage: string);
begin
  WriteLn(StdErr, '[abi] FAIL: ', aMessage);
  Halt(1);
end;

procedure requireCondition(aCondition: Boolean; const aMessage: string);
begin
  if not aCondition then
    fail(aMessage);
end;

procedure checkInt(const aName: string; aLeft: Int64; aRight: Int64; var aFailures: Integer);
begin
  if aLeft <> aRight then
  begin
    Inc(aFailures);
    WriteLn('[abi] mismatch ', aName, ': left=', aLeft, ' right=', aRight);
  end;
end;

procedure checkBool(const aName: string; aLeft: Boolean; aRight: Boolean; var aFailures: Integer);
begin
  if aLeft <> aRight then
  begin
    Inc(aFailures);
    WriteLn('[abi] mismatch ', aName, ': left=', Ord(aLeft), ' right=', Ord(aRight));
  end;
end;

procedure checkFloat(const aName: string; aLeft: Single; aRight: Single; var aFailures: Integer);
begin
  if not SameValue(aLeft, aRight, 1e-6) then
  begin
    Inc(aFailures);
    WriteLn('[abi] mismatch ', aName, ': left=', FloatToStr(aLeft), ' right=', FloatToStr(aRight));
  end;
end;

function functionAddress(const aLibHandle: TLibHandle; const aName: PChar): Pointer;
begin
  Result := GetProcedureAddress(aLibHandle, aName);
  if Result = nil then
    fail(Format('missing export %s', [string(aName)]));
end;

procedure prependDllDirToPath(const aDllDir: string);
var
  pathValue: string;
begin
  pathValue := SysUtils.GetEnvironmentVariable('PATH');
  if Pos(LowerCase(aDllDir), LowerCase(pathValue)) = 0 then
    Windows.SetEnvironmentVariable('PATH', PChar(aDllDir + ';' + pathValue));
end;

procedure loadWhisperLibrary;
var
  exeDir: string;
  dllDir: string;
  dllPath: string;
begin
  exeDir := ExtractFileDir(ExpandFileName(ParamStr(0)));
  dllDir := ExpandFileName(exeDir + '\..\..\..\releases\1.8.4');
  dllPath := IncludeTrailingPathDelimiter(dllDir) + 'whisper.dll';
  requireCondition(FileExists(dllPath), 'whisper.dll not found at ' + dllPath);
  prependDllDirToPath(dllDir);
  gWhisperHandle := SafeLoadLibrary(dllPath);
  requireCondition(gWhisperHandle <> 0, 'failed to load whisper.dll from ' + dllPath);

  Pointer(gWhisperVersion) := functionAddress(gWhisperHandle, 'whisper_version');
  Pointer(gWhisperFree) := functionAddress(gWhisperHandle, 'whisper_free');
  Pointer(gWhisperInitState) := functionAddress(gWhisperHandle, 'whisper_init_state');
  Pointer(gWhisperFreeState) := functionAddress(gWhisperHandle, 'whisper_free_state');
  Pointer(gWhisperFreeParams) := functionAddress(gWhisperHandle, 'whisper_free_params');
  Pointer(gWhisperFreeContextParams) := functionAddress(gWhisperHandle, 'whisper_free_context_params');
  Pointer(gWhisperContextDefaultParams) := functionAddress(gWhisperHandle, 'whisper_context_default_params');
  Pointer(gWhisperContextDefaultParamsByRef) := functionAddress(gWhisperHandle, 'whisper_context_default_params_by_ref');
  Pointer(gWhisperFullDefaultParams) := functionAddress(gWhisperHandle, 'whisper_full_default_params');
  Pointer(gWhisperFullDefaultParamsByRef) := functionAddress(gWhisperHandle, 'whisper_full_default_params_by_ref');
  Pointer(gWhisperInitFromFileWithParamsNoState) := functionAddress(gWhisperHandle, 'whisper_init_from_file_with_params_no_state');
end;

procedure validateContextParams;
var
  failures: Integer;
  byRefParams: PWhisperContextParams;
  byValueParams: TWhisperContextParams;
begin
  WriteLn('[abi] sizeof(Boolean)=', SizeOf(Boolean));
  WriteLn('[abi] sizeof(TWhisperContextParams)=', SizeOf(TWhisperContextParams));
  requireCondition(SizeOf(Boolean) = 1, 'Pascal Boolean must be 1 byte');

  byRefParams := gWhisperContextDefaultParamsByRef();
  requireCondition(byRefParams <> nil, 'whisper_context_default_params_by_ref returned nil');
  byValueParams := gWhisperContextDefaultParams();

  failures := 0;
  checkBool('context.useGpu', byRefParams^.useGpu, byValueParams.useGpu, failures);
  checkBool('context.flashAttn', byRefParams^.flashAttn, byValueParams.flashAttn, failures);
  checkInt('context.gpuDevice', byRefParams^.gpuDevice, byValueParams.gpuDevice, failures);
  checkBool('context.dtwTokenTimestamps', byRefParams^.dtwTokenTimestamps, byValueParams.dtwTokenTimestamps, failures);
  checkInt('context.dtwAheadsPreset', byRefParams^.dtwAheadsPreset, byValueParams.dtwAheadsPreset, failures);
  checkInt('context.dtwNTop', byRefParams^.dtwNTop, byValueParams.dtwNTop, failures);
  checkInt('context.dtwAheads.nHeads', byRefParams^.dtwAheads.nHeads, byValueParams.dtwAheads.nHeads, failures);
  checkInt('context.dtwMemSize', byRefParams^.dtwMemSize, byValueParams.dtwMemSize, failures);

  if CompareMem(byRefParams, @byValueParams, SizeOf(TWhisperContextParams)) then
    WriteLn('[abi] context params raw bytes match')
  else
    WriteLn('[abi] context params raw bytes differ (likely padding)');

  gWhisperFreeContextParams(byRefParams);
  requireCondition(failures = 0, Format('%d context param mismatches detected', [failures]));
end;

procedure validateFullParams;
var
  failures: Integer;
  byRefParams: PWhisperFullParams;
  byValueParams: TWhisperFullParams;
begin
  WriteLn('[abi] sizeof(TWhisperFullParams)=', SizeOf(TWhisperFullParams));
  byRefParams := gWhisperFullDefaultParamsByRef(WHISPER_SAMPLING_GREEDY);
  requireCondition(byRefParams <> nil, 'whisper_full_default_params_by_ref returned nil');
  byValueParams := gWhisperFullDefaultParams(WHISPER_SAMPLING_GREEDY);

  failures := 0;
  checkInt('full.strategy', byRefParams^.strategy, byValueParams.strategy, failures);
  checkInt('full.nThreads', byRefParams^.nThreads, byValueParams.nThreads, failures);
  checkInt('full.nMaxTextCtx', byRefParams^.nMaxTextCtx, byValueParams.nMaxTextCtx, failures);
  checkInt('full.offsetMs', byRefParams^.offsetMs, byValueParams.offsetMs, failures);
  checkInt('full.durationMs', byRefParams^.durationMs, byValueParams.durationMs, failures);
  checkBool('full.translate', byRefParams^.translate, byValueParams.translate, failures);
  checkBool('full.noContext', byRefParams^.noContext, byValueParams.noContext, failures);
  checkBool('full.noTimestamps', byRefParams^.noTimestamps, byValueParams.noTimestamps, failures);
  checkBool('full.singleSegment', byRefParams^.singleSegment, byValueParams.singleSegment, failures);
  checkBool('full.printSpecial', byRefParams^.printSpecial, byValueParams.printSpecial, failures);
  checkBool('full.printProgress', byRefParams^.printProgress, byValueParams.printProgress, failures);
  checkBool('full.printRealtime', byRefParams^.printRealtime, byValueParams.printRealtime, failures);
  checkBool('full.printTimestamps', byRefParams^.printTimestamps, byValueParams.printTimestamps, failures);
  checkBool('full.tokenTimestamps', byRefParams^.tokenTimestamps, byValueParams.tokenTimestamps, failures);
  checkFloat('full.tholdPt', byRefParams^.tholdPt, byValueParams.tholdPt, failures);
  checkFloat('full.tholdPtSum', byRefParams^.tholdPtSum, byValueParams.tholdPtSum, failures);
  checkInt('full.maxLen', byRefParams^.maxLen, byValueParams.maxLen, failures);
  checkBool('full.splitOnWord', byRefParams^.splitOnWord, byValueParams.splitOnWord, failures);
  checkInt('full.maxTokens', byRefParams^.maxTokens, byValueParams.maxTokens, failures);
  checkBool('full.debugMode', byRefParams^.debugMode, byValueParams.debugMode, failures);
  checkInt('full.audioCtx', byRefParams^.audioCtx, byValueParams.audioCtx, failures);
  checkBool('full.tdrzEnable', byRefParams^.tdrzEnable, byValueParams.tdrzEnable, failures);
  checkBool('full.carryInitialPrompt', byRefParams^.carryInitialPrompt, byValueParams.carryInitialPrompt, failures);
  checkInt('full.promptNTokens', byRefParams^.promptNTokens, byValueParams.promptNTokens, failures);
  checkBool('full.detectLanguage', byRefParams^.detectLanguage, byValueParams.detectLanguage, failures);
  checkBool('full.suppressBlank', byRefParams^.suppressBlank, byValueParams.suppressBlank, failures);
  checkBool('full.suppressNst', byRefParams^.suppressNst, byValueParams.suppressNst, failures);
  checkFloat('full.temperature', byRefParams^.temperature, byValueParams.temperature, failures);
  checkFloat('full.maxInitialTs', byRefParams^.maxInitialTs, byValueParams.maxInitialTs, failures);
  checkFloat('full.lengthPenalty', byRefParams^.lengthPenalty, byValueParams.lengthPenalty, failures);
  checkFloat('full.temperatureInc', byRefParams^.temperatureInc, byValueParams.temperatureInc, failures);
  checkFloat('full.entropyThold', byRefParams^.entropyThold, byValueParams.entropyThold, failures);
  checkFloat('full.logprobThold', byRefParams^.logprobThold, byValueParams.logprobThold, failures);
  checkFloat('full.noSpeechThold', byRefParams^.noSpeechThold, byValueParams.noSpeechThold, failures);
  checkInt('full.greedy.bestOf', byRefParams^.greedy.bestOf, byValueParams.greedy.bestOf, failures);
  checkInt('full.beamSearch.beamSize', byRefParams^.beamSearch.beamSize, byValueParams.beamSearch.beamSize, failures);
  checkFloat('full.beamSearch.patience', byRefParams^.beamSearch.patience, byValueParams.beamSearch.patience, failures);
  checkInt('full.nGrammarRules', byRefParams^.nGrammarRules, byValueParams.nGrammarRules, failures);
  checkInt('full.iStartRule', byRefParams^.iStartRule, byValueParams.iStartRule, failures);
  checkFloat('full.grammarPenalty', byRefParams^.grammarPenalty, byValueParams.grammarPenalty, failures);
  checkBool('full.vad', byRefParams^.vad, byValueParams.vad, failures);
  checkFloat('full.vad.threshold', byRefParams^.vadParams.threshold, byValueParams.vadParams.threshold, failures);
  checkInt('full.vad.minSpeechDurationMs', byRefParams^.vadParams.minSpeechDurationMs, byValueParams.vadParams.minSpeechDurationMs, failures);
  checkInt('full.vad.minSilenceDurationMs', byRefParams^.vadParams.minSilenceDurationMs, byValueParams.vadParams.minSilenceDurationMs, failures);
  checkFloat('full.vad.maxSpeechDurationS', byRefParams^.vadParams.maxSpeechDurationS, byValueParams.vadParams.maxSpeechDurationS, failures);
  checkInt('full.vad.speechPadMs', byRefParams^.vadParams.speechPadMs, byValueParams.vadParams.speechPadMs, failures);
  checkFloat('full.vad.samplesOverlap', byRefParams^.vadParams.samplesOverlap, byValueParams.vadParams.samplesOverlap, failures);

  if CompareMem(byRefParams, @byValueParams, SizeOf(TWhisperFullParams)) then
    WriteLn('[abi] full params raw bytes match')
  else
    WriteLn('[abi] full params raw bytes differ (likely padding or internal pointers)');

  gWhisperFreeParams(byRefParams);
  requireCondition(failures = 0, Format('%d full param mismatches detected', [failures]));
end;

procedure validateModelInit(const aModelPath: string);
var
  state: PWhisperState;
  ctx: PWhisperContext;
  params: TWhisperContextParams;
begin
  WriteLn('[abi] init probe model=', aModelPath);
  requireCondition(FileExists(aModelPath), 'model file not found: ' + aModelPath);
  params := gWhisperContextDefaultParams();
  ctx := gWhisperInitFromFileWithParamsNoState(PChar(aModelPath), params);
  requireCondition(ctx <> nil, 'whisper_init_from_file_with_params_no_state returned nil');
  state := gWhisperInitState(ctx);
  requireCondition(state <> nil, 'whisper_init_state returned nil');
  gWhisperFreeState(state);
  gWhisperFree(ctx);
  WriteLn('[abi] init probe ok');
end;

var
  modelPath: string;
begin
  SetExceptionMask([
    exInvalidOp,
    exDenormalized,
    exZeroDivide,
    exOverflow,
    exUnderflow,
    exPrecision
  ]);
  loadWhisperLibrary;
  WriteLn('[abi] whisper_version=', safeCString(gWhisperVersion()));
  validateContextParams;
  validateFullParams;
  if ParamCount >= 1 then
  begin
    modelPath := ExpandFileName(ParamStr(1));
    validateModelInit(modelPath);
  end;
  if gWhisperHandle <> 0 then
    FreeLibrary(gWhisperHandle);
  WriteLn('[abi] PASS');
end.