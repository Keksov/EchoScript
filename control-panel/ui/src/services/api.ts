import type {
  ConfigResponse,
  DaemonStatus,
  DownloadResult,
  HealthResponse,
  ModelStatus,
  PickPathResult,
  RestartResult,
  SaveResult,
  SchemaResponse,
  ServiceAction,
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

export const controlService = async (name: string, action: ServiceAction): Promise<RestartResult> => {
  const response = await fetch(`/api/services/${encodeURIComponent(name)}/${action}`, { method: "POST" })
  return (await response.json()) as RestartResult
}

export const fetchModels = async (): Promise<ModelStatus[]> => {
  const payload = await getJson<{ models: ModelStatus[] }>("/api/models")
  return payload.models
}

export const downloadModel = async (id: string): Promise<DownloadResult> => {
  const response = await fetch(`/api/models/${encodeURIComponent(id)}/download`, { method: "POST" })
  return (await response.json()) as DownloadResult
}

export const pickPath = async (kind: "directory" | "file", start: string): Promise<PickPathResult> => {
  const response = await fetch("/api/pick-path", {
    method: "POST",
    headers: jsonHeaders,
    body: JSON.stringify({ kind, start }),
  })
  return (await response.json()) as PickPathResult
}

type JsonRecord = Record<string, unknown> & { error?: string }

const sendJson = async (path: string, method: string, body?: unknown): Promise<JsonRecord> => {
  const response = await fetch(path, {
    method,
    headers: jsonHeaders,
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  })
  const payload = (await response.json().catch(() => ({}))) as JsonRecord
  if (!response.ok) {
    throw new Error(payload.error ?? `${method} ${path} failed: ${response.status}`)
  }
  return payload
}

/** Create a ws-daemon instance (engine/model required; port auto-allocated if omitted). */
export const addDaemon = (body: Record<string, unknown>): Promise<JsonRecord> =>
  sendJson("/api/daemons", "POST", body)

/** Edit a ws-daemon instance (model/port/settings). */
export const editDaemon = (name: string, body: Record<string, unknown>): Promise<JsonRecord> =>
  sendJson(`/api/daemons/${encodeURIComponent(name)}`, "PATCH", body)

/** Remove a ws-daemon instance. */
export const removeDaemon = (name: string): Promise<JsonRecord> =>
  sendJson(`/api/daemons/${encodeURIComponent(name)}`, "DELETE")

/** Open echotail log tabs (Windows Terminal) for every running daemon. */
export const openDaemonTabs = (): Promise<JsonRecord> =>
  sendJson("/api/daemons/tabs", "POST")

/** Delete a model. dryRun previews; force cascades (removes referencing instances). */
export const deleteModel = (id: string, opts: { force?: boolean; dryRun?: boolean }): Promise<JsonRecord> => {
  const qs = new URLSearchParams()
  if (opts.force === true) qs.set("force", "true")
  if (opts.dryRun === true) qs.set("dryRun", "true")
  const suffix = qs.toString() === "" ? "" : `?${qs.toString()}`
  return sendJson(`/api/models/${encodeURIComponent(id)}${suffix}`, "DELETE")
}
