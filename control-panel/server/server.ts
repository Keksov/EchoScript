import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import { configJsonPath, publicDir, repoRoot, resolveServerPort, SERVER_HOST } from "./config"
import { readDaemonStatuses } from "./status"
import { pickPath, type PickerKind } from "./directory-picker"
import { applyConfig } from "./settings"
import { WS_DAEMON_FIELDS } from "./settings-schema"
import { controlService, serviceNames, type ServiceAction } from "./services-control"
import { echoctlExe, echoctlDaemonNames, runEchoctl, runEchoctlJson } from "./echoctl"

const port = resolveServerPort()

const json = (value: unknown, status = 200): Response =>
  new Response(JSON.stringify(value), {
    status,
    headers: { "content-type": "application/json" },
  })

/** Serve the built Quasar bundle from public/, falling back to index.html (hash routing). */
const serveStatic = (request: Request): Response => {
  const url = new URL(request.url)
  const requested = url.pathname === "/" ? "/index.html" : url.pathname
  const resolved = resolve(publicDir, `.${requested}`)
  if (!resolved.startsWith(publicDir)) {
    return new Response("Not found", { status: 404 })
  }
  const finalPath = existsSync(resolved) ? resolved : join(publicDir, "index.html")
  if (!existsSync(finalPath)) {
    return new Response("UI bundle is missing — run `bun run build` in control-panel/ui/.", {
      status: 503,
    })
  }
  return new Response(Bun.file(finalPath))
}

const readConfig = async (): Promise<unknown> => {
  try {
    return JSON.parse(await readFile(configJsonPath, "utf-8"))
  } catch {
    return null
  }
}

/** echoctl models list → the UI's ModelStatus shape (size_mb → sizeMb; downloading is async). */
interface EchoctlModel {
  id: string
  model: string
  kind: string
  model_name: string
  downloadable: boolean
  downloaded: boolean
  size_mb: number | null
  note: string | null
  paths: string[]
}
const mapModels = (rows: EchoctlModel[]): unknown[] =>
  rows.map((m) => ({
    id: m.id,
    model: m.model,
    kind: m.kind,
    modelName: m.model_name,
    downloadable: m.downloadable,
    downloaded: m.downloaded,
    sizeMb: m.size_mb,
    downloading: false,
    note: m.note,
    paths: m.paths,
  }))

const asRecord = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null ? (value as Record<string, unknown>) : {}

/** Build `echoctl daemons add/edit` args from a request body. */
const daemonMutationArgs = (base: string[], body: Record<string, unknown>): string[] => {
  const args = [...base]
  if (typeof body.engine === "string") args.push("--engine", body.engine)
  if (typeof body.model === "string") args.push("--model", body.model)
  if (body.port !== undefined && body.port !== null) args.push("--port", String(body.port))
  if (typeof body.host === "string") args.push("--host", body.host)
  if (typeof body.language === "string") args.push("--lang", body.language)
  if (typeof body.name === "string") args.push("--name", body.name)
  const settings = asRecord(body.settings)
  for (const [key, value] of Object.entries(settings)) {
    args.push("--set", `${key}=${String(value)}`)
  }
  return args
}

const echoctlResponse = async (args: string[]): Promise<Response> => {
  const run = await runEchoctlJson(args)
  if (run.ok) {
    return json(run.data ?? { ok: true })
  }
  return json({ error: run.stderr.trim() || `echoctl exited ${run.code}` }, 400)
}

const handleApi = async (request: Request, pathname: string): Promise<Response> => {
  if (pathname === "/api/health" && request.method === "GET") {
    return json({ ok: true, service: "echoscript-control-panel", port })
  }
  if (pathname === "/api/config" && request.method === "GET") {
    const config = await readConfig()
    if (config === null) {
      return json({ error: "config.json not found or invalid", path: configJsonPath }, 500)
    }
    const resolved: Record<string, string> = {}
    for (const key of ["jobs_root", "ffmpeg_path"]) {
      const value = (config as Record<string, unknown>)[key]
      if (typeof value === "string" && value.length > 0) {
        resolved[key] = resolve(repoRoot, value)
      }
    }
    return json({ path: configJsonPath, config, resolved })
  }
  // Bulk settings PUT still goes through applyConfig; DF5.2 migrates the UI to granular
  // echoctl config-set / daemons-edit calls, after which this can shell out too.
  if (pathname === "/api/config" && request.method === "PUT") {
    let body: unknown
    try {
      body = await request.json()
    } catch {
      return json({ error: "invalid JSON body" }, 400)
    }
    try {
      const result = await applyConfig(body)
      return json({ path: configJsonPath, config: result.config, restartRequired: result.restartRequired })
    } catch (error) {
      const code = (error as Error & { code?: string }).code
      const message = error instanceof Error ? error.message : String(error)
      return json({ error: message }, code === "VALIDATION" ? 400 : 500)
    }
  }
  if (pathname === "/api/schema" && request.method === "GET") {
    // Orchestrator field schema comes from echoctl (single source); daemon per-instance
    // fields stay in TS until the UI settings form is reworked (DF5.2).
    const orch = await runEchoctlJson<unknown[]>(["config", "schema"])
    return json({ orchestrator: orch.data ?? [], wsDaemon: WS_DAEMON_FIELDS })
  }
  if (pathname === "/api/daemons" && request.method === "GET") {
    const controllable = new Set([...serviceNames(), ...(await echoctlDaemonNames())])
    const daemons = (await readDaemonStatuses()).map((d) => ({ ...d, controllable: controllable.has(d.name) }))
    return json({ daemons })
  }
  // Create a ws-daemon instance.
  if (pathname === "/api/daemons" && request.method === "POST") {
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>
    return echoctlResponse(daemonMutationArgs(["daemons", "add"], body))
  }
  // Remove / edit a ws-daemon instance.
  const daemonMatch = /^\/api\/daemons\/([^/]+)$/u.exec(pathname)
  if (daemonMatch !== null && request.method === "DELETE") {
    return echoctlResponse(["daemons", "remove", decodeURIComponent(daemonMatch[1]!)])
  }
  if (daemonMatch !== null && request.method === "PATCH") {
    const body = (await request.json().catch(() => ({}))) as Record<string, unknown>
    return echoctlResponse(daemonMutationArgs(["daemons", "edit", decodeURIComponent(daemonMatch[1]!)], body))
  }
  if (pathname === "/api/orchestrator/restart" && request.method === "POST") {
    const result = await controlService("orchestrator", "restart")
    return json(result, result.ok ? 200 : 500)
  }
  // /api/services/<name>/<start|stop|restart>: ws_daemons via echoctl (socket-safe launch),
  // everything else (orchestrator, streaming vosk inventory) via the lifecycle scripts.
  const serviceMatch = /^\/api\/services\/([^/]+)\/(start|stop|restart)$/u.exec(pathname)
  if (serviceMatch !== null && request.method === "POST") {
    const name = decodeURIComponent(serviceMatch[1]!)
    const action = serviceMatch[2] as ServiceAction
    if ((await echoctlDaemonNames()).has(name)) {
      const run = await runEchoctl(["daemons", action, name])
      return json(
        { ok: run.ok, output: (run.ok ? run.stdout : run.stderr).trim() },
        run.ok ? 200 : 500,
      )
    }
    const result = await controlService(name, action)
    return json(result, result.ok ? 200 : 500)
  }
  if (pathname === "/api/pick-path" && request.method === "POST") {
    const body = (await request.json().catch(() => ({}))) as { kind?: string; start?: string }
    const kind: PickerKind = body.kind === "file" ? "file" : "directory"
    const result = await pickPath(kind, typeof body.start === "string" ? body.start : "")
    return json(result)
  }
  if (pathname === "/api/models" && request.method === "GET") {
    const run = await runEchoctlJson<EchoctlModel[]>(["models", "list"])
    return json({ models: mapModels(run.data ?? []) })
  }
  const downloadMatch = /^\/api\/models\/([^/]+)\/download$/u.exec(pathname)
  if (downloadMatch !== null && request.method === "POST") {
    const id = decodeURIComponent(downloadMatch[1]!)
    const list = await runEchoctlJson<EchoctlModel[]>(["models", "list"])
    const entry = (list.data ?? []).find((m) => m.id === id)
    if (entry === undefined) {
      return json({ started: false, reason: "unknown model id" }, 409)
    }
    if (!entry.downloadable) {
      return json({ started: false, reason: "not script-downloadable" }, 409)
    }
    if (entry.downloaded) {
      return json({ started: true, note: "already downloaded" }, 202)
    }
    // Fire-and-forget: the download can take minutes; the UI polls /api/models for state.
    Bun.spawn([echoctlExe, "models", "download", id, "--json"], {
      cwd: repoRoot,
      stdio: ["ignore", "ignore", "ignore"],
    })
    return json({ started: true }, 202)
  }
  // Delete a model (refuse-if-referenced; ?force=true cascades, ?dryRun=true previews).
  const modelMatch = /^\/api\/models\/([^/]+)$/u.exec(pathname)
  if (modelMatch !== null && request.method === "DELETE") {
    const id = decodeURIComponent(modelMatch[1]!)
    const search = new URL(request.url).searchParams
    const args = ["models", "delete", id]
    if (search.get("dryRun") === "true") args.push("--dry-run")
    if (search.get("force") === "true") args.push("--force")
    return echoctlResponse(args)
  }
  return json({ error: "not found" }, 404)
}

const server = Bun.serve({
  port,
  hostname: SERVER_HOST,
  // Daemon/orchestrator restart shells out to stop+start (cold pwsh ~several seconds),
  // longer than the 10s default — give requests room before the idle cutoff.
  idleTimeout: 60,
  async fetch(request) {
    const { pathname } = new URL(request.url)
    if (pathname.startsWith("/api/")) {
      try {
        return await handleApi(request, pathname)
      } catch (error) {
        return json({ error: error instanceof Error ? error.message : String(error) }, 500)
      }
    }
    return serveStatic(request)
  },
})

console.log(`[control-panel] listening on http://${server.hostname}:${server.port}`)
