export type ServiceKind = "orchestrator" | "ws-daemon" | "vosk-daemon"

export interface DaemonStatus {
  readonly name: string
  readonly kind: ServiceKind
  readonly up: boolean
  readonly detail: string
  readonly modelName: string | null
  readonly engine: string | null
  readonly language: string | null
  readonly host: string
  readonly port: number
  readonly configured: boolean
  readonly registered: boolean
  readonly fresh: boolean
  readonly state: string | null
  readonly pid: number | null
  readonly updatedAt: string | null
  readonly ageMs: number | null
  readonly controllable?: boolean
}

export type ServiceAction = "start" | "stop" | "restart"

export interface ConfigResponse {
  readonly path: string
  readonly config: Record<string, unknown>
  readonly resolved?: Record<string, string>
}

export interface HealthResponse {
  readonly ok: boolean
  readonly service: string
  readonly port: number
}

export type ReloadClass = "hot" | "restart"
export type FieldType = "int" | "float" | "string" | "select" | "bool"
export type FieldTarget = "orchestrator" | "daemon"

export interface FieldSpec {
  readonly key: string
  readonly type: FieldType
  readonly reload: ReloadClass
  readonly target?: FieldTarget
  readonly engine?: string
  readonly min?: number
  readonly max?: number
  readonly optionsFrom?: "models"
  readonly default?: string | number | boolean
  readonly picker?: "directory" | "file"
}

export interface SchemaResponse {
  readonly orchestrator: FieldSpec[]
  readonly wsDaemon: FieldSpec[]
}

export interface PickPathResult {
  readonly path: string | null
  readonly cancelled: boolean
}

export interface SaveResult {
  readonly path: string
  readonly config: Record<string, unknown>
  readonly restartRequired: boolean
}

export interface RestartResult {
  readonly ok: boolean
  readonly output: string
}

export interface ModelStatus {
  readonly id: string
  readonly model: string
  readonly kind: "language" | "vad" | "diarization"
  readonly modelName: string
  readonly downloadable: boolean
  readonly downloaded: boolean
  readonly sizeMb: number | null
  readonly downloading: boolean
  readonly note: string | null
  readonly paths: string[]
}

export interface DownloadResult {
  readonly started: boolean
  readonly reason?: string
}
