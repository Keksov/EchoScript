import path from "node:path";
import { readdir } from "node:fs/promises";

import { claimMediaFile, rejectMixedFile, UNROUTED_DIR_NAME } from "./file-drop";
import type { EngineRouting } from "./engine-routing";

/**
 * Scan jobs/input/ for dropped raw files and turn each into a job — the capability the old
 * python watcher had that the orchestrator lost. Two layouts (LG-D1, design gate):
 *
 *  - input/<engine>/<language>/  — the language subfolder is resolved to a concrete model
 *    at intake (EngineRouting) and the job carries `language`. A file dropped directly in
 *    input/<engine>/ (no language subfolder) means "mixed" and is rejected until P4:
 *    moved to input/<engine>/_unrouted/ rather than transcribed with the wrong language.
 *  - input/<model>/  — legacy flat model dirs, scanned exactly as before (no language).
 *
 * Also recovers orphaned `.processing` claims (a crash between claim and job creation).
 * Idempotent and safe to run from startup, an fs.watch event, or the reconcile tick.
 */

const PROCESSING_SUFFIX = ".processing";

/** Minimal JobManager surface this needs (satisfied by JobManager). */
export interface DropJobSink {
  createDroppedJob(
    processingPath: string,
    originalFilename: string,
    modelName: string,
    meta?: { readonly language?: string },
  ): Promise<{ readonly jobId: string }>;
  enqueueJob(jobId: string, params: Record<string, unknown>): Promise<unknown>;
}

/** What to scan: legacy flat model dirs plus engine/<language> routing (see EngineRouting). */
export interface DropRouting {
  readonly legacyModels: readonly string[];
  readonly engines: EngineRouting;
}

const bootstrapAndEnqueue = async (
  sink: DropJobSink,
  processingPath: string,
  originalFilename: string,
  modelName: string,
  language: string | null,
): Promise<string> => {
  const meta = language !== null ? { language } : undefined;
  const { jobId } = await sink.createDroppedJob(processingPath, originalFilename, modelName, meta);
  await sink.enqueueJob(jobId, language !== null ? { language } : {});
  return jobId;
};

/** Turn one filename in a (model, language) dir into a job (or recover its orphan claim). */
const processFileEntry = async (
  dir: string,
  entry: string,
  modelName: string,
  language: string | null,
  stableMs: number,
  sink: DropJobSink,
): Promise<string | null> => {
  if (entry.endsWith(PROCESSING_SUFFIX)) {
    // Orphaned claim (crash before job creation) — bootstrap it now.
    const originalFilename = entry.slice(0, -PROCESSING_SUFFIX.length);
    return bootstrapAndEnqueue(sink, path.join(dir, entry), originalFilename, modelName, language);
  }

  const claimed = await claimMediaFile(dir, entry, stableMs);
  if (claimed === null) {
    return null;
  }
  return bootstrapAndEnqueue(sink, claimed.processingPath, claimed.originalFilename, modelName, language);
};

const scanFlatModelDir = async (
  jobsRoot: string,
  modelName: string,
  stableMs: number,
  sink: DropJobSink,
  created: string[],
): Promise<void> => {
  const dir = path.join(jobsRoot, "input", modelName);
  let entries: string[];
  try {
    entries = await readdir(dir);
  } catch {
    return; // dir missing — nothing to sweep
  }
  for (const entry of entries) {
    try {
      const jobId = await processFileEntry(dir, entry, modelName, null, stableMs, sink);
      if (jobId !== null) {
        created.push(jobId);
      }
    } catch (error) {
      console.error(`file-drop: failed to process ${path.join(dir, entry)}`, error);
    }
  }
};

const scanEngineDir = async (
  jobsRoot: string,
  engine: string,
  langMap: ReadonlyMap<string, string>,
  stableMs: number,
  sink: DropJobSink,
  created: string[],
): Promise<void> => {
  const engineDir = path.join(jobsRoot, "input", engine);
  let entries: import("node:fs").Dirent[];
  try {
    entries = await readdir(engineDir, { withFileTypes: true });
  } catch {
    return; // engine dir missing — nothing to sweep
  }

  for (const entry of entries) {
    try {
      if (entry.isDirectory()) {
        const language = entry.name.toLowerCase();
        if (language === UNROUTED_DIR_NAME) {
          continue; // parked mixed drops — leave them
        }
        const modelName = langMap.get(language);
        if (modelName === undefined) {
          // A subfolder that is not a configured language for this engine — leave it (could
          // be a typo or a language whose daemon/model is not staged yet).
          console.warn(
            `file-drop: unconfigured language '${entry.name}' under engine '${engine}' — skipping`,
          );
          continue;
        }
        const langDir = path.join(engineDir, entry.name);
        let files: string[];
        try {
          files = await readdir(langDir);
        } catch {
          continue;
        }
        for (const file of files) {
          const jobId = await processFileEntry(langDir, file, modelName, language, stableMs, sink);
          if (jobId !== null) {
            created.push(jobId);
          }
        }
      } else {
        // File dropped directly in the engine root (no language subfolder) = mixed → reject
        // until P4 (LG-D1). Moving it to _unrouted/ keeps it out of the next sweep.
        const moved = await rejectMixedFile(engineDir, entry.name, stableMs);
        if (moved !== null) {
          console.warn(
            `file-drop: '${entry.name}' dropped in engine '${engine}' root without a language ` +
              `subfolder (mixed) — parked in ${UNROUTED_DIR_NAME}/ until multi-language lands (P4)`,
          );
        }
      }
    } catch (error) {
      console.error(`file-drop: failed to process ${path.join(engineDir, entry.name)}`, error);
    }
  }
};

/** Returns the jobIds created this sweep. */
export const scanInputDrops = async (
  jobsRoot: string,
  routing: DropRouting,
  stableMs: number,
  sink: DropJobSink,
): Promise<string[]> => {
  const created: string[] = [];

  for (const [engine, langMap] of routing.engines) {
    await scanEngineDir(jobsRoot, engine, langMap, stableMs, sink, created);
  }
  for (const modelName of routing.legacyModels) {
    await scanFlatModelDir(jobsRoot, modelName, stableMs, sink, created);
  }

  return created;
};
