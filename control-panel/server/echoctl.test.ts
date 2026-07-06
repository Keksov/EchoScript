import { expect, test } from "bun:test"

import { echoctlDaemonNames, runEchoctlJson } from "./echoctl"

// These shell out to the real echoctl.exe (must be built) against the repo config.json.

test("daemons list returns the configured ws_daemons", async () => {
  const run = await runEchoctlJson<Array<{ name: string; engine: string }>>(["daemons", "list"])
  expect(run.ok).toBe(true)
  expect(Array.isArray(run.data)).toBe(true)
  const names = (run.data ?? []).map((d) => d.name)
  expect(names).toContain("whisperdaemon")
})

test("models list returns models with the expected fields", async () => {
  const run = await runEchoctlJson<Array<{ id: string; downloadable: boolean; downloaded: boolean }>>([
    "models",
    "list",
  ])
  expect(run.ok).toBe(true)
  const ids = (run.data ?? []).map((m) => m.id)
  expect(ids).toContain("en")
  expect(ids).toContain("vosk_ru")
})

test("config schema returns orchestrator fields with reload classes", async () => {
  const run = await runEchoctlJson<Array<{ key: string; reload: string }>>(["config", "schema"])
  expect(run.ok).toBe(true)
  const byKey = new Map((run.data ?? []).map((f) => [f.key, f.reload]))
  expect(byKey.get("max_workers")).toBe("restart")
  expect(byKey.get("poll_interval_ms")).toBe("hot")
})

test("echoctlDaemonNames includes configured instances", async () => {
  const names = await echoctlDaemonNames()
  expect(names.has("whisperdaemon")).toBe(true)
})
