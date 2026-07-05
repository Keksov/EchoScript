import { dirname, join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export const serverDir = dirname(fileURLToPath(import.meta.url))
// control-panel/server -> control-panel -> repo root (EchoScript)
export const repoRoot = resolve(serverDir, "..", "..")

/** The single source of truth the control-server reads (and, from P2, writes). */
export const configJsonPath = join(repoRoot, "config.json")
/** Daemon self-registration dir (jobs/registry/<model_name>.json). */
export const registryDir = join(repoRoot, "jobs", "registry")

export const publicDir = join(serverDir, "public")

const DEFAULT_PORT = 3001

const parsePort = (rawValue: string): number => {
  const value = Number(rawValue.trim())
  if (!Number.isInteger(value) || value < 1 || value > 65535) {
    throw new Error(`Invalid control-panel port: ${rawValue}`)
  }
  return value
}

/** Port for the control-plane server; env override, else 3001 (data plane is :3000). */
export const resolveServerPort = (): number => {
  const raw = Bun.env.PORT ?? Bun.env.CONTROL_PANEL_PORT
  if (raw === undefined || raw.trim() === "") {
    return DEFAULT_PORT
  }
  return parsePort(raw)
}

/** Bind localhost-only — the control plane edits config and controls processes (CP-D9). */
export const SERVER_HOST = "127.0.0.1"
