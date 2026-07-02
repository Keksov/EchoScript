import { watch, type FSWatcher } from "node:fs";
import { mkdir, readdir, readFile } from "node:fs/promises";
import path from "node:path";

import { DaemonRegistry, parseRegistration } from "./daemon-registry";

/**
 * Thin fs wrapper that feeds the pure DaemonRegistry from jobs/registry/<name>.json:
 * ensure the dir exists, do a startup scan, and watch for changes. Registration files
 * are keyed by filename stem, which must equal the record's `name` (DR-D5 convention);
 * a mismatched or half-written file is ignored (last good entry kept), and a removed
 * file drops the entry. The pure readiness/TTL logic lives in daemon-registry.ts.
 */

export const REGISTRY_DIR_NAME = "registry";

export const registryDir = (jobsRoot: string): string => path.join(jobsRoot, REGISTRY_DIR_NAME);

type Reader = (filePath: string) => Promise<string>;

const defaultReader: Reader = (filePath) => readFile(filePath, "utf-8");

const stemOf = (fileName: string): string | null =>
  fileName.endsWith(".json") ? fileName.slice(0, -".json".length) : null;

/**
 * Load one registration file into the registry. Missing/unreadable file -> remove the
 * entry; unparseable/malformed/misfiled content -> ignore (keep the previous entry).
 */
export const loadRegistryFile = async (
  dir: string,
  fileName: string,
  registry: DaemonRegistry,
  reader: Reader = defaultReader,
): Promise<void> => {
  const stem = stemOf(fileName);
  if (stem === null) {
    return;
  }

  let text: string;
  try {
    text = await reader(path.join(dir, fileName));
  } catch {
    registry.remove(stem);
    return;
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(text);
  } catch {
    return; // half-written; keep the last good entry
  }

  const reg = parseRegistration(parsed);
  if (reg !== null && reg.name === stem) {
    registry.upsert(reg);
  }
};

/** Rebuild the registry from a full scan of the registry dir. */
export const scanRegistryDir = async (
  dir: string,
  registry: DaemonRegistry,
  reader: Reader = defaultReader,
): Promise<void> => {
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    registry.clear();
    return;
  }
  registry.clear();
  for (const entry of entries) {
    await loadRegistryFile(dir, entry, registry, reader);
  }
};

export interface RegistryWatcher {
  close(): void;
}

/**
 * Ensure jobs/registry/ exists (the orchestrator owns it — DR-D5), seed the registry
 * with a startup scan, and watch for subsequent changes.
 */
export const startRegistryWatcher = async (
  jobsRoot: string,
  registry: DaemonRegistry,
): Promise<RegistryWatcher> => {
  const dir = registryDir(jobsRoot);
  await mkdir(dir, { recursive: true });
  await scanRegistryDir(dir, registry);

  const watcher: FSWatcher = watch(dir, (_eventType, filename) => {
    if (filename === null) {
      return;
    }
    const name = String(filename);
    if (!name.endsWith(".json")) {
      return;
    }
    void loadRegistryFile(dir, name, registry).catch(() => undefined);
  });

  return {
    close: (): void => watcher.close(),
  };
};
