import { readdir, readFile } from "node:fs/promises"
import { connect } from "node:net"
import { join } from "node:path"

import { configJsonPath, orchestratorEndpoint, registryDir } from "./config"

const DEFAULT_REGISTRY_TTL_MS = 15000

export type ServiceKind = "orchestrator" | "ws-daemon"

export interface WsDaemonConfig {
  readonly host?: string
  readonly port?: number
  readonly engine?: string
  readonly language?: string
  readonly model_name?: string
}

export interface RegistryEntry {
  readonly name?: string
  readonly host?: string
  readonly port?: number
  readonly model_name?: string
  readonly state?: string
  readonly pid?: number
  readonly updated_at?: string
}

export interface DaemonStatus {
  readonly name: string
  readonly kind: ServiceKind
  /** Effectively up/ready: ws-daemon = fresh registry heartbeat; orchestrator = port open. */
  readonly up: boolean
  /** Short status token for the UI: ready | stale | down | orphan | listening. */
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

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

const ageMsOf = (updatedAt: string | undefined, now: number): number | null => {
  if (updatedAt === undefined) {
    return null
  }
  const parsed = Date.parse(updatedAt)
  return Number.isNaN(parsed) ? null : now - parsed
}

/**
 * Merge configured ws_daemons with live registry entries (pure). A daemon is "fresh"
 * (effectively ready) when its registry heartbeat is within the registry TTL — the same
 * rule the orchestrator's readiness-gate uses. Registry entries with no matching config
 * entry are surfaced as `configured: false` orphans.
 */
export const computeDaemonStatuses = (
  wsDaemons: Readonly<Record<string, WsDaemonConfig>>,
  registry: readonly RegistryEntry[],
  ttlMs: number,
  now: number,
): DaemonStatus[] => {
  const byModel = new Map<string, RegistryEntry>()
  for (const entry of registry) {
    if (typeof entry.model_name === "string") {
      byModel.set(entry.model_name, entry)
    }
  }

  const statuses: DaemonStatus[] = []
  const seenModels = new Set<string>()

  for (const [name, cfg] of Object.entries(wsDaemons)) {
    const modelName = cfg.model_name ?? name
    seenModels.add(modelName)
    const reg = byModel.get(modelName)
    const ageMs = ageMsOf(reg?.updated_at, now)
    const fresh = reg !== undefined && ageMs !== null && ageMs <= ttlMs
    statuses.push({
      name,
      kind: "ws-daemon",
      up: fresh,
      detail: fresh ? "ready" : reg !== undefined ? "stale" : "down",
      modelName,
      engine: cfg.engine ?? null,
      language: cfg.language ?? null,
      host: reg?.host ?? cfg.host ?? "127.0.0.1",
      port: reg?.port ?? cfg.port ?? 0,
      configured: true,
      registered: reg !== undefined,
      fresh,
      state: reg?.state ?? null,
      pid: reg?.pid ?? null,
      updatedAt: reg?.updated_at ?? null,
      ageMs,
    })
  }

  // Registry entries with no matching config (orphans / stale) — surface them too.
  for (const entry of registry) {
    const modelName = entry.model_name
    if (typeof modelName !== "string" || seenModels.has(modelName)) {
      continue
    }
    const ageMs = ageMsOf(entry.updated_at, now)
    const fresh = ageMs !== null && ageMs <= ttlMs
    statuses.push({
      name: entry.name ?? modelName,
      kind: "ws-daemon",
      up: fresh,
      detail: "orphan",
      modelName,
      engine: null,
      language: null,
      host: entry.host ?? "127.0.0.1",
      port: entry.port ?? 0,
      configured: false,
      registered: true,
      fresh,
      state: entry.state ?? null,
      pid: entry.pid ?? null,
      updatedAt: entry.updated_at ?? null,
      ageMs,
    })
  }

  return statuses
}

/** TCP port probe (proxy-immune, unlike fetch) — is anything listening on host:port? */
export const isPortOpen = (host: string, port: number, timeoutMs = 800): Promise<boolean> =>
  new Promise((resolve) => {
    const socket = connect({ host, port })
    const finish = (value: boolean): void => {
      socket.destroy()
      resolve(value)
    }
    socket.setTimeout(timeoutMs)
    socket.once("connect", () => finish(true))
    socket.once("timeout", () => finish(false))
    socket.once("error", () => finish(false))
  })

/** Build the orchestrator's service status from a port probe (it is not in the registry). */
export const orchestratorStatus = (host: string, port: number, up: boolean): DaemonStatus => ({
  name: "orchestrator",
  kind: "orchestrator",
  up,
  detail: up ? "listening" : "down",
  modelName: null,
  engine: null,
  language: null,
  host,
  port,
  configured: true,
  registered: false,
  fresh: up,
  state: up ? "listening" : null,
  pid: null,
  updatedAt: null,
  ageMs: null,
})

const readJson = async (path: string): Promise<unknown> => {
  try {
    return JSON.parse(await readFile(path, "utf-8"))
  } catch {
    return null
  }
}

/** Read config.json + jobs/registry/ and produce the merged daemon status list. */
export const readDaemonStatuses = async (now: number = Date.now()): Promise<DaemonStatus[]> => {
  const config = await readJson(configJsonPath)
  const wsDaemons =
    isRecord(config) && isRecord(config.ws_daemons)
      ? (config.ws_daemons as Record<string, WsDaemonConfig>)
      : {}
  const ttlMs =
    isRecord(config) && typeof config.daemon_registry_ttl_ms === "number"
      ? config.daemon_registry_ttl_ms
      : DEFAULT_REGISTRY_TTL_MS

  let files: string[]
  try {
    files = (await readdir(registryDir)).filter((f) => f.endsWith(".json"))
  } catch {
    files = []
  }

  const registry: RegistryEntry[] = []
  for (const file of files) {
    const entry = await readJson(join(registryDir, file))
    if (isRecord(entry)) {
      registry.push(entry as RegistryEntry)
    }
  }

  // Orchestrator (data plane) first — status via TCP port probe, then the ws-daemons.
  const orch = orchestratorEndpoint()
  const orchestrator = orchestratorStatus(orch.host, orch.port, await isPortOpen(orch.host, orch.port))
  return [orchestrator, ...computeDaemonStatuses(wsDaemons, registry, ttlMs, now)]
}
