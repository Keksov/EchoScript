import { join } from "node:path"

import { repoRoot } from "./config"

/**
 * Thin proxy to the echoctl FPC CLI — the single engine that owns config.json mutations,
 * the model lifecycle, and ws-daemon instance CRUD/lifecycle (DF-D1). The control-server
 * shells out to it and forwards the JSON, so the panel is a wrapper, not a second writer.
 */
export const echoctlExe = join(repoRoot, "echoctl", "build", "x64", "echoctl.exe")

export interface EchoctlRun {
  readonly ok: boolean
  readonly code: number
  readonly stdout: string
  readonly stderr: string
}

/** Run echoctl with the given args (echoctl resolves config.json/manifest near its exe). */
export const runEchoctl = async (args: readonly string[]): Promise<EchoctlRun> => {
  const proc = Bun.spawn([echoctlExe, ...args], {
    cwd: repoRoot,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
  ])
  const code = await proc.exited
  return { ok: code === 0, code, stdout, stderr }
}

export interface EchoctlJson<T> {
  readonly ok: boolean
  readonly code: number
  readonly data: T | null
  readonly stderr: string
}

/** Run echoctl with --json appended and parse stdout. data is null on non-JSON output. */
export const runEchoctlJson = async <T = unknown>(args: readonly string[]): Promise<EchoctlJson<T>> => {
  const run = await runEchoctl([...args, "--json"])
  let data: T | null = null
  try {
    data = JSON.parse(run.stdout) as T
  } catch {
    data = null
  }
  return { ok: run.ok, code: run.code, data, stderr: run.stderr }
}

/** The set of ws_daemons instance names echoctl manages (used to dispatch service control). */
export const echoctlDaemonNames = async (): Promise<Set<string>> => {
  const run = await runEchoctlJson<Array<{ name: string }>>(["daemons", "list"])
  if (!run.ok || run.data === null) {
    return new Set()
  }
  return new Set(run.data.map((d) => d.name))
}
