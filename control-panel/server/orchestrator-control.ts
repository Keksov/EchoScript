import { spawn } from "node:child_process"
import { join } from "node:path"

import { repoRoot } from "./config"

export interface ScriptResult {
  readonly code: number
  readonly output: string
}

/** Run a repo-relative .bat via cmd (Windows), collecting stdout+stderr. */
export const runScript = (relScript: string): Promise<ScriptResult> =>
  new Promise((resolve) => {
    const scriptPath = join(repoRoot, relScript)
    const child = spawn("cmd", ["/c", scriptPath], { cwd: repoRoot, windowsHide: true })
    let output = ""
    child.stdout.on("data", (chunk) => {
      output += chunk.toString()
    })
    child.stderr.on("data", (chunk) => {
      output += chunk.toString()
    })
    child.on("close", (code) => resolve({ code: code ?? -1, output }))
    child.on("error", (error) => resolve({ code: -1, output: String(error) }))
  })

const sleep = (ms: number): Promise<void> => new Promise((resolve) => setTimeout(resolve, ms))

/**
 * Restart the orchestrator (data plane) via its stop/start scripts so restart-class config
 * changes take effect. The start script detaches the process, so it outlives this call.
 */
export const restartOrchestrator = async (): Promise<{ ok: boolean; output: string }> => {
  const stop = await runScript("orchestrator/scripts/stop_orchestrator.bat")
  await sleep(1000)
  const start = await runScript("orchestrator/scripts/start_orchestrator.bat")
  return { ok: start.code === 0, output: `${stop.output}\n${start.output}`.trim() }
}
