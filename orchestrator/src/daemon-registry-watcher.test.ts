import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, rm, writeFile, unlink } from "node:fs/promises";

import { DaemonRegistry } from "./daemon-registry";
import { registryDir, loadRegistryFile, scanRegistryDir } from "./daemon-registry-watcher";

const reg = (overrides: Record<string, unknown> = {}): string =>
  JSON.stringify({
    name: "whisperdaemon",
    host: "127.0.0.1",
    port: 7801,
    model_name: "whisper_podlodka",
    state: "ready",
    pid: 1,
    input: { codec: "pcm16le", sample_rate_hz: 16000, channels: 1 },
    updated_at: new Date().toISOString(),
    ...overrides,
  });

test("registryDir joins jobsRoot/registry", () => {
  expect(registryDir("C:/x/jobs")).toBe(path.join("C:/x/jobs", "registry"));
});

test("scanRegistryDir seeds the registry from files (fresh -> ready)", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "reg-scan-"));
  try {
    await writeFile(path.join(dir, "whisperdaemon.json"), reg());
    await writeFile(path.join(dir, "voskru.json"), reg({ name: "voskru", model_name: "vosk_ru", port: 7701 }));

    const registry = new DaemonRegistry(15000);
    await scanRegistryDir(dir, registry);

    expect(registry.isReady("whisperdaemon")).toBe(true);
    expect(registry.readyForModel("vosk_ru")?.name).toBe("voskru");
    expect(registry.readyNames().sort()).toEqual(["voskru", "whisperdaemon"]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("scanRegistryDir on a missing dir clears the registry (no throw)", async () => {
  const registry = new DaemonRegistry(15000);
  await scanRegistryDir(path.join(tmpdir(), `does-not-exist-${crypto.randomUUID()}`), registry);
  expect(registry.readyNames()).toEqual([]);
});

test("loadRegistryFile: upsert, ignore half-written, remove on unlink", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "reg-load-"));
  try {
    const registry = new DaemonRegistry(15000);
    const file = "whisperdaemon.json";

    await writeFile(path.join(dir, file), reg());
    await loadRegistryFile(dir, file, registry);
    expect(registry.isReady("whisperdaemon")).toBe(true);

    // half-written JSON -> keep previous good entry
    await writeFile(path.join(dir, file), "{ not json");
    await loadRegistryFile(dir, file, registry);
    expect(registry.isReady("whisperdaemon")).toBe(true);

    // file removed -> entry dropped
    await unlink(path.join(dir, file));
    await loadRegistryFile(dir, file, registry);
    expect(registry.get("whisperdaemon")).toBeNull();
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test("loadRegistryFile ignores non-json and misfiled records (name != stem)", async () => {
  const dir = await mkdtemp(path.join(tmpdir(), "reg-mis-"));
  try {
    const registry = new DaemonRegistry(15000);
    await writeFile(path.join(dir, "notes.txt"), "ignored");
    await loadRegistryFile(dir, "notes.txt", registry);
    // file named wrong.json but content.name = whisperdaemon -> ignored (keyed by stem)
    await writeFile(path.join(dir, "wrong.json"), reg());
    await loadRegistryFile(dir, "wrong.json", registry);
    expect(registry.readyNames()).toEqual([]);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
