import path from "node:path";
import { readdir } from "node:fs/promises";

import { claimMediaFile } from "./file-drop";

/**
 * Scan jobs/input/<model>/ for dropped raw files and turn each into a job — the
 * capability the old python watcher had that the orchestrator lost. Also recovers
 * orphaned `.processing` claims (a crash between claim and job creation). Idempotent
 * and safe to run from startup, an fs.watch event, or the reconcile tick.
 */

const PROCESSING_SUFFIX = ".processing";

/** Minimal JobManager surface this needs (satisfied by JobManager). */
export interface DropJobSink {
  createDroppedJob(
    processingPath: string,
    originalFilename: string,
    modelName: string,
  ): Promise<{ readonly jobId: string }>;
  enqueueJob(jobId: string, params: Record<string, unknown>): Promise<unknown>;
}

const bootstrapAndEnqueue = async (
  sink: DropJobSink,
  processingPath: string,
  originalFilename: string,
  modelName: string,
): Promise<string> => {
  const { jobId } = await sink.createDroppedJob(processingPath, originalFilename, modelName);
  await sink.enqueueJob(jobId, {});
  return jobId;
};

const processEntry = async (
  dir: string,
  entry: string,
  modelName: string,
  stableMs: number,
  sink: DropJobSink,
): Promise<string | null> => {
  if (entry.endsWith(PROCESSING_SUFFIX)) {
    // Orphaned claim (crash before job creation) — bootstrap it now.
    const originalFilename = entry.slice(0, -PROCESSING_SUFFIX.length);
    return bootstrapAndEnqueue(sink, path.join(dir, entry), originalFilename, modelName);
  }

  const claimed = await claimMediaFile(dir, entry, stableMs);
  if (claimed === null) {
    return null;
  }
  return bootstrapAndEnqueue(sink, claimed.processingPath, claimed.originalFilename, modelName);
};

/** Returns the jobIds created this sweep. */
export const scanInputDrops = async (
  jobsRoot: string,
  modelNames: readonly string[],
  stableMs: number,
  sink: DropJobSink,
): Promise<string[]> => {
  const created: string[] = [];
  for (const modelName of modelNames) {
    const dir = path.join(jobsRoot, "input", modelName);
    let entries: string[];
    try {
      entries = await readdir(dir);
    } catch {
      continue; // dir missing — nothing to sweep
    }
    for (const entry of entries) {
      try {
        const jobId = await processEntry(dir, entry, modelName, stableMs, sink);
        if (jobId !== null) {
          created.push(jobId);
        }
      } catch (error) {
        console.error(`file-drop: failed to process ${path.join(dir, entry)}`, error);
      }
    }
  }
  return created;
};
