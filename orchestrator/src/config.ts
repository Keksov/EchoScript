import { readFile } from "node:fs/promises";
import path from "node:path";
import process from "node:process";

export interface ModelConfig {
  readonly serviceDir: string;
  readonly pythonExecutable: string;
  readonly module: string;
}

export interface SpeechConfig {
  readonly commandGrammars: Readonly<Record<string, readonly string[]>>;
}

export interface WsDaemonConfig {
  readonly host: string;
  readonly port: number;
  readonly modelName: string;
}

export interface AppConfig {
  readonly projectRoot: string;
  readonly jobsRoot: string;
  readonly allowedInputRoots: readonly string[];
  readonly maxWorkers: number;
  readonly pollIntervalMs: number;
  readonly modelStopTimeoutMs: number;
  readonly streamWindowMs: number;
  readonly streamRolloverMs: number;
  readonly daemonRegistryTtlMs: number;
  readonly dropStableMs: number;
  readonly maxRequeueAttempts: number;
  readonly defaultModel: string;
  readonly ffmpegPath: string;
  readonly speech: SpeechConfig;
  readonly models: Readonly<Record<string, ModelConfig>>;
  readonly wsDaemons: Readonly<Record<string, WsDaemonConfig>>;
}

interface RawModelConfig {
  readonly service_dir?: unknown;
  readonly python_executable?: unknown;
  readonly module?: unknown;
}

interface RawSpeechConfig {
  readonly command_grammars?: unknown;
}

interface RawConfig {
  readonly jobs_root?: unknown;
  readonly allowed_input_roots?: unknown;
  readonly max_workers?: unknown;
  readonly poll_interval_ms?: unknown;
  readonly model_stop_timeout_ms?: unknown;
  readonly stream_window_ms?: unknown;
  readonly stream_rollover_ms?: unknown;
  readonly daemon_registry_ttl_ms?: unknown;
  readonly drop_stable_ms?: unknown;
  readonly max_requeue_attempts?: unknown;
  readonly default_model?: unknown;
  readonly ffmpeg_path?: unknown;
  readonly speech?: unknown;
  readonly models?: unknown;
  readonly ws_daemons?: unknown;
}

const defaultVenvPython = process.platform === "win32" ? "venv/Scripts/python.exe" : "venv/bin/python";

const defaultModel = (serviceDir: string): { readonly serviceDir: string; readonly pythonExecutable: string; readonly module: string } => {
  return {
    serviceDir,
    pythonExecutable: `${serviceDir}/${defaultVenvPython}`,
    module: "app.main",
  };
};

const DEFAULT_MODELS = {
  whisper_podlodka: defaultModel("services/whisper_podlodka"),
  borealis: defaultModel("services/borealis"),
  gemma4: defaultModel("services/gemma4"),
  vibevoice: defaultModel("services/vibevoice"),
} as const;

const DEFAULT_JOBS_ROOT = "./jobs";
const DEFAULT_MAX_WORKERS = 1;
const DEFAULT_POLL_INTERVAL_MS = 500;
const DEFAULT_MODEL_STOP_TIMEOUT_MS = 120000;
// Streaming file bridge (see orchestrator/spec/file-streaming-bridge-plan.md, SB-D3/SB-D8):
// window of audio streamed per binary frame, and rollover cap before a fresh session.
const DEFAULT_STREAM_WINDOW_MS = 30000;
const DEFAULT_STREAM_ROLLOVER_MS = 1200000;
// Daemon registry (jobs/registry/<name>.json): a registration is "ready" only if its
// heartbeat is within this TTL (invariant: TTL >= ~3x the daemon heartbeat interval).
const DEFAULT_DAEMON_REGISTRY_TTL_MS = 15000;
// A dropped file in jobs/input/<model>/ is claimed only after its mtime has been stable
// for this long (guards against claiming a large file mid-copy — DR-D3).
const DEFAULT_DROP_STABLE_MS = 2000;
// Max times a ws-daemon job may be requeued after a transport failure before it is
// failed terminally — guards against an infinite requeue loop (SR-D1).
const DEFAULT_MAX_REQUEUE_ATTEMPTS = 5;
const DEFAULT_MODEL = "whisper_podlodka";
const DEFAULT_FFMPEG_PATH = "./tools/ffmpeg/ffmpeg.exe";
const JOBS_ROOT_ENV = "ECHOSCRIPT_JOBS_ROOT";
const FFMPEG_PATH_ENV = "ECHOSCRIPT_FFMPEG_PATH";
const DEFAULT_COMMAND_GRAMMARS = {
  ru: ["вверх", "вниз", "дальше", "назад", "пауза", "старт", "стоп"],
} as const;

export const PROJECT_ROOT = path.resolve(import.meta.dir, "..", "..");

const isRecord = (value: unknown): value is Record<string, unknown> => {
  return typeof value === "object" && value !== null && !Array.isArray(value);
};

const asString = (value: unknown): string | null => {
  return typeof value === "string" && value.length > 0 ? value : null;
};

const asNumber = (value: unknown): number | null => {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
};

const asStringArray = (value: unknown): string[] => {
  if (!Array.isArray(value)) {
    return [];
  }

  return value.filter((item): item is string => typeof item === "string" && item.length > 0);
};

const asTrimmedStringArray = (value: unknown): string[] => {
  return asStringArray(value)
    .map((item) => item.trim())
    .filter((item) => item.length > 0);
};

const normalizePythonExecutableForPlatform = (pythonExecutable: string): string => {
  if (process.platform === "win32") {
    return pythonExecutable.replace(/venv[\\/]+bin[\\/]+python$/i, "venv/Scripts/python.exe");
  }

  return pythonExecutable.replace(/venv[\\/]+scripts[\\/]+python\.exe$/i, "venv/bin/python");
};

const resolveModelConfig = (
  projectRoot: string,
  modelName: string,
  rawConfig: RawModelConfig | null,
): ModelConfig => {
  const defaults = DEFAULT_MODELS[modelName as keyof typeof DEFAULT_MODELS];
  const serviceDir = asString(rawConfig?.service_dir) ?? defaults?.serviceDir ?? null;
  const pythonExecutable =
    asString(rawConfig?.python_executable) ?? defaults?.pythonExecutable ?? null;
  const moduleName = asString(rawConfig?.module) ?? defaults?.module ?? null;

  if (serviceDir === null || pythonExecutable === null || moduleName === null) {
    throw new Error(`Incomplete model config for ${modelName}`);
  }

  return {
    serviceDir: path.resolve(projectRoot, serviceDir),
    pythonExecutable: path.resolve(projectRoot, normalizePythonExecutableForPlatform(pythonExecutable)),
    module: moduleName,
  };
};

const resolveSpeechConfig = (rawConfig: RawSpeechConfig | null): SpeechConfig => {
  const commandGrammars: Record<string, readonly string[]> = {};

  for (const [language, grammar] of Object.entries(DEFAULT_COMMAND_GRAMMARS)) {
    commandGrammars[language] = [...grammar];
  }

  const rawCommandGrammars = rawConfig !== null && isRecord(rawConfig.command_grammars)
    ? rawConfig.command_grammars
    : null;

  if (rawCommandGrammars !== null) {
    for (const [language, rawGrammar] of Object.entries(rawCommandGrammars)) {
      const normalizedGrammar = [...new Set(asTrimmedStringArray(rawGrammar))];
      if (normalizedGrammar.length > 0) {
        commandGrammars[language] = normalizedGrammar;
      }
    }
  }

  return {
    commandGrammars,
  };
};

const resolveWsDaemons = (raw: unknown): Record<string, WsDaemonConfig> => {
  const result: Record<string, WsDaemonConfig> = {};
  if (!isRecord(raw)) {
    return result;
  }

  for (const [name, value] of Object.entries(raw)) {
    if (!isRecord(value)) {
      continue;
    }

    const port = asNumber(value.port);
    if (port === null) {
      throw new Error(`ws_daemons.${name}: numeric port is required`);
    }

    result[name] = {
      host: asString(value.host) ?? "127.0.0.1",
      port,
      modelName: asString(value.model_name) ?? name,
    };
  }

  return result;
};

export const loadConfig = async (): Promise<AppConfig> => {
  const configPath = path.join(PROJECT_ROOT, "config.json");
  const rawText = await readFile(configPath, "utf-8");
  const parsed: unknown = JSON.parse(rawText);
  if (!isRecord(parsed)) {
    throw new Error("config.json must contain a JSON object");
  }

  const rawConfig = parsed as RawConfig;
  const rawModels = isRecord(rawConfig.models) ? rawConfig.models : {};
  const modelNames = new Set<string>([
    ...Object.keys(DEFAULT_MODELS),
    ...Object.keys(rawModels),
  ]);

  const models: Record<string, ModelConfig> = {};
  for (const modelName of modelNames) {
    const modelValue = rawModels[modelName];
    const modelConfig = isRecord(modelValue) ? (modelValue as RawModelConfig) : null;
    models[modelName] = resolveModelConfig(PROJECT_ROOT, modelName, modelConfig);
  }

  const defaultModel = asString(rawConfig.default_model) ?? DEFAULT_MODEL;
  if (!(defaultModel in models)) {
    throw new Error(`default_model is not defined in models: ${defaultModel}`);
  }

  const maxWorkers = Math.max(1, asNumber(rawConfig.max_workers) ?? DEFAULT_MAX_WORKERS);
  const pollIntervalMs = Math.max(
    100,
    asNumber(rawConfig.poll_interval_ms) ?? DEFAULT_POLL_INTERVAL_MS,
  );
  const modelStopTimeoutMs = Math.max(
    1000,
    asNumber(rawConfig.model_stop_timeout_ms) ?? DEFAULT_MODEL_STOP_TIMEOUT_MS,
  );
  const streamWindowMs = Math.max(1000, asNumber(rawConfig.stream_window_ms) ?? DEFAULT_STREAM_WINDOW_MS);
  const streamRolloverMs = Math.max(
    streamWindowMs,
    asNumber(rawConfig.stream_rollover_ms) ?? DEFAULT_STREAM_ROLLOVER_MS,
  );
  const daemonRegistryTtlMs = Math.max(
    1000,
    asNumber(rawConfig.daemon_registry_ttl_ms) ?? DEFAULT_DAEMON_REGISTRY_TTL_MS,
  );
  const dropStableMs = Math.max(0, asNumber(rawConfig.drop_stable_ms) ?? DEFAULT_DROP_STABLE_MS);
  const maxRequeueAttempts = Math.max(
    0,
    Math.trunc(asNumber(rawConfig.max_requeue_attempts) ?? DEFAULT_MAX_REQUEUE_ATTEMPTS),
  );
  const jobsRootOverride = asString(process.env[JOBS_ROOT_ENV]);
  const configuredJobsRoot = jobsRootOverride ?? asString(rawConfig.jobs_root) ?? DEFAULT_JOBS_ROOT;
  const ffmpegOverride = asString(process.env[FFMPEG_PATH_ENV]);
  const configuredFfmpegPath = ffmpegOverride ?? asString(rawConfig.ffmpeg_path) ?? DEFAULT_FFMPEG_PATH;
  const configuredAllowedRoots = asStringArray(rawConfig.allowed_input_roots);
  const allowedInputRoots = (configuredAllowedRoots.length > 0 ? configuredAllowedRoots : [PROJECT_ROOT]).map(
    (rootPath) => path.resolve(PROJECT_ROOT, rootPath),
  );

  return {
    projectRoot: PROJECT_ROOT,
    jobsRoot: path.resolve(PROJECT_ROOT, configuredJobsRoot),
    allowedInputRoots: [...new Set(allowedInputRoots)],
    maxWorkers,
    pollIntervalMs,
    modelStopTimeoutMs,
    streamWindowMs,
    streamRolloverMs,
    daemonRegistryTtlMs,
    dropStableMs,
    maxRequeueAttempts,
    defaultModel,
    ffmpegPath: path.resolve(PROJECT_ROOT, configuredFfmpegPath),
    speech: resolveSpeechConfig(isRecord(rawConfig.speech) ? (rawConfig.speech as RawSpeechConfig) : null),
    models,
    wsDaemons: resolveWsDaemons(rawConfig.ws_daemons),
  };
};