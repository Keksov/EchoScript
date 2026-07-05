import { spawn } from "node:child_process"
import { readFileSync } from "node:fs"
import { join } from "node:path"

import { configJsonPath, orchestratorEndpoint, repoRoot, serverDir } from "./config"
import { isPortOpen } from "./status"

export type ServiceAction = "start" | "stop" | "restart"

interface ServiceScripts {
  readonly start_script: string
  readonly stop_script: string
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
  return null
}

/**
 * Run a repo-relative .bat detached with no inherited handles (stdio "ignore" — piping
 * hands the child our listening socket on Windows, see CP2.1). Verified via port probe.
 */
const runScriptDetached = (relScript: string): Promise<number> =>
  new Promise((resolve) => {
    const child = spawn("cmd", ["/c", join(repoRoot, relScript)], {
      cwd: repoRoot,
      windowsHide: true,
      stdio: "ignore",
      detached: true,
    })
    child.once("close", (code) => resolve(code ?? -1))
    child.once("error", () => resolve(-1))
    child.unref()
  })

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
  const verify = async (wantOpen: boolean, timeoutMs: number): Promise<boolean> =>
    endpoint === null ? true : waitForPort(endpoint.host, endpoint.port, wantOpen, timeoutMs)

  if (action === "stop") {
    await runScriptDetached(scripts.stop_script)
    const down = await verify(false, STOP_TIMEOUT_MS)
    return { ok: down, output: down ? `${name} stopped` : `${name} still listening after stop` }
  }

  if (action === "start") {
    await runScriptDetached(scripts.start_script)
    const up = await verify(true, START_TIMEOUT_MS)
    return { ok: up, output: up ? `${name} started` : `${name} did not come up within timeout` }
  }

  // restart
  await runScriptDetached(scripts.stop_script)
  await verify(false, STOP_TIMEOUT_MS)
  await runScriptDetached(scripts.start_script)
  const up = await verify(true, START_TIMEOUT_MS)
  return { ok: up, output: up ? `${name} restarted` : `${name} did not come back up within timeout` }
}
