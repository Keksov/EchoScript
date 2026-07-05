import { readFileSync } from "node:fs"
import { join } from "node:path"

import { configJsonPath, orchestratorEndpoint, repoRoot, serverDir } from "./config"
import { isPortOpen } from "./status"
import { DAEMON_ENV_MAP } from "./settings-schema"

export type ServiceAction = "start" | "stop" | "restart"

interface ServiceScripts {
  readonly start_script: string
  readonly stop_script: string
  readonly host?: string
  readonly port?: number
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)

/** Load the lifecycle inventory (control-panel/server/services.json). */
const loadInventory = (): Record<string, ServiceScripts> => {
  try {
    const raw: unknown = JSON.parse(readFileSync(join(serverDir, "services.json"), "utf-8"))
    if (isRecord(raw) && isRecord(raw.services)) {
      return raw.services as Record<string, ServiceScripts>
    }
  } catch {
    // fall through
  }
  return {}
}

export const serviceNames = (): string[] => Object.keys(loadInventory())

/** Endpoint used to verify a service came up/down (orchestrator vs ws_daemon from config). */
const resolveEndpoint = (name: string): { host: string; port: number } | null => {
  if (name === "orchestrator") {
    return orchestratorEndpoint()
  }
  try {
    const cfg: unknown = JSON.parse(readFileSync(configJsonPath, "utf-8"))
    if (isRecord(cfg) && isRecord(cfg.ws_daemons) && isRecord(cfg.ws_daemons[name])) {
      const daemon = cfg.ws_daemons[name] as { host?: string; port?: number }
      if (typeof daemon.port === "number") {
        return { host: daemon.host ?? "127.0.0.1", port: daemon.port }
      }
    }
  } catch {
    // fall through
  }
  // inventory-declared host/port (vosk daemons — not in config.ws_daemons)
  const entry = loadInventory()[name]
  if (entry !== undefined && typeof entry.port === "number") {
    return { host: entry.host ?? "127.0.0.1", port: entry.port }
  }
  return null
}

/**
 * Daemon launch env from config (CP4.1): the daemon reads VAD/decode/GPU tuning from env,
 * which we set here from ws_daemons.<name> before starting it (the start script + Start-Process
 * inherit this environment). Absent/blank config values are skipped (daemon keeps its default).
 */
const daemonEnvFromConfig = (name: string): Record<string, string> => {
  const env: Record<string, string> = {}
  try {
    const cfg: unknown = JSON.parse(readFileSync(configJsonPath, "utf-8"))
    if (isRecord(cfg) && isRecord(cfg.ws_daemons) && isRecord(cfg.ws_daemons[name])) {
      const daemon = cfg.ws_daemons[name] as Record<string, unknown>
      for (const [key, envVar] of Object.entries(DAEMON_ENV_MAP)) {
        const value = daemon[key]
        if (value === undefined || value === null || value === "") {
          continue
        }
        env[envVar] = typeof value === "boolean" ? (value ? "1" : "0") : String(value)
      }
    }
  } catch {
    // fall through — no overrides
  }
  return env
}

/**
 * Launch a repo-relative .bat via Bun.spawn with ignored stdio.
 *
 * Known limitation (Windows): Bun.serve's listening socket is inheritable, and a launched
 * daemon (via the start script's `Start-Process -RedirectStandardOutput`) inherits it, so it
 * keeps :3001 bound after the control-server exits. This only surfaces if the control-server
 * is restarted while daemons it launched are still running — free :3001 (stop those daemons,
 * or start the control-server before the daemons) in that case. Normal operation is fine.
 */
const runScriptDetached = async (relScript: string, extraEnv?: Record<string, string>): Promise<number> => {
  const proc = Bun.spawn(["cmd", "/c", join(repoRoot, relScript)], {
    cwd: repoRoot,
    env: (extraEnv === undefined ? process.env : { ...process.env, ...extraEnv }) as Record<string, string>,
    stdio: ["ignore", "ignore", "ignore"],
  })
  return proc.exited
}

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

const waitForPort = async (
  host: string,
  port: number,
  wantOpen: boolean,
  timeoutMs: number,
  intervalMs = 500,
): Promise<boolean> => {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    if ((await isPortOpen(host, port, 400)) === wantOpen) {
      return true
    }
    if (Date.now() >= deadline) {
      return false
    }
    await sleep(intervalMs)
  }
}

// Daemon start includes model warmup (whisper ~seconds to tens of seconds).
const START_TIMEOUT_MS = 60000
const STOP_TIMEOUT_MS = 10000

/**
 * start / stop / restart a service by name via its scripts, confirming the outcome with a
 * port probe. Works for the orchestrator and the ws-daemons alike (CP3.1).
 */
export const controlService = async (
  name: string,
  action: ServiceAction,
): Promise<{ ok: boolean; output: string }> => {
  const scripts = loadInventory()[name]
  if (scripts === undefined) {
    return { ok: false, output: `unknown service: ${name}` }
  }
  const endpoint = resolveEndpoint(name)
  const startEnv = daemonEnvFromConfig(name)
  const verify = async (wantOpen: boolean, timeoutMs: number): Promise<boolean> =>
    endpoint === null ? true : waitForPort(endpoint.host, endpoint.port, wantOpen, timeoutMs)

  if (action === "stop") {
    await runScriptDetached(scripts.stop_script)
    const down = await verify(false, STOP_TIMEOUT_MS)
    return { ok: down, output: down ? `${name} stopped` : `${name} still listening after stop` }
  }

  if (action === "start") {
    await runScriptDetached(scripts.start_script, startEnv)
    const up = await verify(true, START_TIMEOUT_MS)
    return { ok: up, output: up ? `${name} started` : `${name} did not come up within timeout` }
  }

  // restart
  await runScriptDetached(scripts.stop_script)
  await verify(false, STOP_TIMEOUT_MS)
  await runScriptDetached(scripts.start_script, startEnv)
  const up = await verify(true, START_TIMEOUT_MS)
  return { ok: up, output: up ? `${name} restarted` : `${name} did not come back up within timeout` }
}
