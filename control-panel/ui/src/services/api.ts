import type { ConfigResponse, DaemonStatus, HealthResponse } from "src/types"

const getJson = async <T>(path: string): Promise<T> => {
  const response = await fetch(path)
  if (!response.ok) {
    throw new Error(`GET ${path} failed: ${response.status}`)
  }
  return (await response.json()) as T
}

export const fetchHealth = (): Promise<HealthResponse> => getJson<HealthResponse>("/api/health")

export const fetchConfig = (): Promise<ConfigResponse> => getJson<ConfigResponse>("/api/config")

export const fetchDaemons = async (): Promise<DaemonStatus[]> => {
  const payload = await getJson<{ daemons: DaemonStatus[] }>("/api/daemons")
  return payload.daemons
}
