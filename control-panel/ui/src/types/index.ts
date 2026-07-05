export type ServiceKind = "orchestrator" | "ws-daemon"

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
}

export interface ConfigResponse {
  readonly path: string
  readonly config: Record<string, unknown>
}

export interface HealthResponse {
  readonly ok: boolean
  readonly service: string
  readonly port: number
}
