import type {
  ConfigResponse,
  DaemonStatus,
  HealthResponse,
  RestartResult,
  SaveResult,
  SchemaResponse,
} from "src/types"

const jsonHeaders = { "content-type": "application/json" }

const getJson = async <T>(path: string): Promise<T> => {
  const response = await fetch(path)
  if (!response.ok) {
    throw new Error(`GET ${path} failed: ${response.status}`)
  }
  return (await response.json()) as T
}

export const fetchHealth = (): Promise<HealthResponse> => getJson<HealthResponse>("/api/health")

export const fetchConfig = (): Promise<ConfigResponse> => getJson<ConfigResponse>("/api/config")

export const fetchSchema = (): Promise<SchemaResponse> => getJson<SchemaResponse>("/api/schema")

export const fetchDaemons = async (): Promise<DaemonStatus[]> => {
  const payload = await getJson<{ daemons: DaemonStatus[] }>("/api/daemons")
  return payload.daemons
}

export const saveConfig = async (patch: Record<string, unknown>): Promise<SaveResult> => {
  const response = await fetch("/api/config", {
    method: "PUT",
    headers: jsonHeaders,
    body: JSON.stringify(patch),
  })
  const payload = (await response.json().catch(() => ({}))) as SaveResult & { error?: string }
  if (!response.ok) {
    throw new Error(payload.error ?? `PUT /api/config failed: ${response.status}`)
  }
  return payload
}

export const restartOrchestrator = async (): Promise<RestartResult> => {
  const response = await fetch("/api/orchestrator/restart", { method: "POST" })
  return (await response.json()) as RestartResult
}
