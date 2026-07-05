/**
 * Declarative schema for the editable settings (CP-D5). Drives server-side validation
 * and the UI forms; i18n labels/descriptions live in the ui locale files keyed by `key`.
 *
 * `reload` classifies how a change is applied by the orchestrator (CP-D3):
 *  - "hot":     the orchestrator re-reads it live (fs.watch → config reload)
 *  - "restart": takes effect only after an orchestrator restart
 */
export type ReloadClass = "hot" | "restart"
export type FieldType = "int" | "string" | "select"

export interface FieldSpec {
  readonly key: string
  readonly type: FieldType
  readonly reload: ReloadClass
  readonly min?: number
  readonly max?: number
  /** For type "select": dynamic option source resolved against the live config. */
  readonly optionsFrom?: "models"
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
  { key: "ffmpeg_path", type: "string", reload: "hot" },
  { key: "jobs_root", type: "string", reload: "restart" },
]

/** Per-daemon fields inside ws_daemons.<name>. */
export const WS_DAEMON_FIELDS: readonly FieldSpec[] = [
  { key: "host", type: "string", reload: "hot" },
  { key: "port", type: "int", reload: "hot", min: 1, max: 65535 },
  { key: "engine", type: "string", reload: "hot" },
  { key: "language", type: "string", reload: "hot" },
  { key: "model_name", type: "string", reload: "hot" },
]

/** Options for a "select" field, resolved against the current config (e.g. model names). */
export const resolveSelectOptions = (spec: FieldSpec, config: Record<string, unknown>): string[] => {
  if (spec.optionsFrom === "models" && typeof config.models === "object" && config.models !== null) {
    return Object.keys(config.models as Record<string, unknown>)
  }
  return []
}
