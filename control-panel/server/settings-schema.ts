/**
 * Declarative schema for the editable settings (CP-D5). Drives server-side validation
 * and the UI forms; i18n labels/descriptions live in the ui locale files keyed by `key`.
 *
 * `reload` classifies how a change is applied by the orchestrator (CP-D3):
 *  - "hot":     the orchestrator re-reads it live (fs.watch → config reload)
 *  - "restart": takes effect only after an orchestrator restart
 */
export type ReloadClass = "hot" | "restart"
export type FieldType = "int" | "float" | "string" | "select" | "bool"
/** Which service a change targets: the orchestrator (data plane) or the daemon itself. */
export type FieldTarget = "orchestrator" | "daemon"

export interface FieldSpec {
  readonly key: string
  readonly type: FieldType
  readonly reload: ReloadClass
  readonly target?: FieldTarget
  readonly min?: number
  readonly max?: number
  /** For type "select": dynamic option source resolved against the live config. */
  readonly optionsFrom?: "models"
  /** Default shown/written when the config has no value (daemon launch fields). */
  readonly default?: string | number | boolean
  /** Show a native OS path picker button next to the field (control-server local pick). */
  readonly picker?: "directory" | "file"
}

/** Top-level orchestrator scalar settings (config.json root keys). */
export const ORCHESTRATOR_FIELDS: readonly FieldSpec[] = [
  { key: "max_workers", type: "int", reload: "restart", min: 1, max: 64 },
  { key: "poll_interval_ms", type: "int", reload: "hot", min: 100, max: 60000 },
  { key: "stream_window_ms", type: "int", reload: "hot", min: 1000, max: 600000 },
  { key: "stream_chunk_ms", type: "int", reload: "hot", min: 1000, max: 3600000 },
  { key: "daemon_registry_ttl_ms", type: "int", reload: "hot", min: 1000, max: 600000 },
  { key: "drop_stable_ms", type: "int", reload: "hot", min: 0, max: 600000 },
  { key: "max_requeue_attempts", type: "int", reload: "hot", min: 0, max: 100 },
  { key: "default_model", type: "select", reload: "hot", optionsFrom: "models" },
  { key: "ffmpeg_path", type: "string", reload: "hot", picker: "file" },
  { key: "jobs_root", type: "string", reload: "restart", picker: "directory" },
]

/**
 * Per-daemon fields inside ws_daemons.<name>. Routing fields (host..model_name) target the
 * orchestrator and hot-reload; launch fields (vad/decode/gpu) target the daemon and take
 * effect only when that daemon is (re)started — the control-panel launcher passes them to
 * the daemon as env at start (CP4.1), each with a conservative default.
 */
export const WS_DAEMON_FIELDS: readonly FieldSpec[] = [
  { key: "host", type: "string", reload: "hot", target: "orchestrator" },
  { key: "port", type: "int", reload: "hot", target: "orchestrator", min: 1, max: 65535 },
  { key: "engine", type: "string", reload: "hot", target: "orchestrator" },
  { key: "language", type: "string", reload: "hot", target: "orchestrator" },
  { key: "model_name", type: "string", reload: "hot", target: "orchestrator" },
  { key: "vad", type: "bool", reload: "restart", target: "daemon", default: true },
  { key: "vad_threshold", type: "float", reload: "restart", target: "daemon", min: 0, max: 1, default: 0.4 },
  { key: "vad_speech_pad_ms", type: "int", reload: "restart", target: "daemon", min: 0, max: 2000, default: 200 },
  { key: "no_speech_thold", type: "float", reload: "restart", target: "daemon", min: 0, max: 1, default: 0.6 },
  { key: "entropy_thold", type: "float", reload: "restart", target: "daemon", min: 0, max: 10, default: 2.4 },
  { key: "gpu", type: "bool", reload: "restart", target: "daemon", default: false },
  { key: "gpu_device", type: "int", reload: "restart", target: "daemon", min: 0, max: 16, default: 0 },
]

/** Config field -> daemon env var (launcher passes these at daemon start, CP4.1). */
export const DAEMON_ENV_MAP: Readonly<Record<string, string>> = {
  vad: "WHISPER_VAD",
  vad_threshold: "WHISPER_VAD_THRESHOLD",
  vad_speech_pad_ms: "WHISPER_VAD_SPEECH_PAD_MS",
  no_speech_thold: "WHISPER_NO_SPEECH_THOLD",
  entropy_thold: "WHISPER_ENTROPY_THOLD",
  gpu: "WHISPER_USE_GPU",
  gpu_device: "WHISPER_GPU_DEVICE",
}

/** Options for a "select" field, resolved against the current config (e.g. model names). */
export const resolveSelectOptions = (spec: FieldSpec, config: Record<string, unknown>): string[] => {
  if (spec.optionsFrom === "models" && typeof config.models === "object" && config.models !== null) {
    return Object.keys(config.models as Record<string, unknown>)
  }
  return []
}
