import { existsSync } from "node:fs"
import { readFile } from "node:fs/promises"
import { join, resolve } from "node:path"

import { configJsonPath, publicDir, resolveServerPort, SERVER_HOST } from "./config"
import { readDaemonStatuses } from "./status"
import { applyConfig } from "./settings"
import { ORCHESTRATOR_FIELDS, WS_DAEMON_FIELDS } from "./settings-schema"
import { restartOrchestrator } from "./orchestrator-control"

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

const handleApi = async (request: Request, pathname: string): Promise<Response> => {
  if (pathname === "/api/health" && request.method === "GET") {
    return json({ ok: true, service: "echoscript-control-panel", port })
  }
  if (pathname === "/api/config" && request.method === "GET") {
    const config = await readConfig()
    if (config === null) {
      return json({ error: "config.json not found or invalid", path: configJsonPath }, 500)
    }
    return json({ path: configJsonPath, config })
  }
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
    return json({ orchestrator: ORCHESTRATOR_FIELDS, wsDaemon: WS_DAEMON_FIELDS })
  }
  if (pathname === "/api/daemons" && request.method === "GET") {
    return json({ daemons: await readDaemonStatuses() })
  }
  if (pathname === "/api/orchestrator/restart" && request.method === "POST") {
    const result = await restartOrchestrator()
    return json(result, result.ok ? 200 : 500)
  }
  return json({ error: "not found" }, 404)
}

const server = Bun.serve({
  port,
  hostname: SERVER_HOST,
  // Daemon/orchestrator restart shells out to stop+start scripts (cold pwsh ~several
  // seconds), longer than the 10s default — give requests room before the idle cutoff.
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
