import { spawn } from "node:child_process"
import { join } from "node:path"

import { orchestratorEndpoint, repoRoot } from "./config"
import { isPortOpen } from "./status"

/**
 * Run a repo-relative .bat detached with no inherited handles. `stdio: "ignore"` matters:
 * piping would hand the child our listening socket on Windows, so a restarted orchestrator
 * would keep :3001 bound after the control-server dies. We verify results via a port probe
 * instead of the script's stdout.
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

/** Poll until the port reaches the desired open/closed state, or the timeout elapses. */
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

/**
 * Restart the orchestrator (data plane) via its stop/start scripts so restart-class config
 * changes take effect. Waits for the port to drop, then to come back up, and reports the
 * outcome by probing :3000 (not by capturing script output).
 */
export const restartOrchestrator = async (): Promise<{ ok: boolean; output: string }> => {
  const { host, port } = orchestratorEndpoint()
  await runScriptDetached("orchestrator/scripts/stop_orchestrator.bat")
  await waitForPort(host, port, false, 8000)
  await runScriptDetached("orchestrator/scripts/start_orchestrator.bat")
  const up = await waitForPort(host, port, true, 25000)
  return {
    ok: up,
    output: up
      ? `orchestrator restarted, listening on ${host}:${port}`
      : `orchestrator did not come back up on ${host}:${port} within timeout`,
  }
}
