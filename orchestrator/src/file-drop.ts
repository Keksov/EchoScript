import path from "node:path";
import { createHash } from "node:crypto";
import { stat as fsStat, rename as fsRename } from "node:fs/promises";

/**
 * File-drop core (pure) — restores the old python watcher behaviour: raw media files
 * dropped into jobs/input/<model>/ become jobs. This module owns the framework-free
 * pieces: transliteration + job-id building (mirrors _build_media_job_id) and claiming
 * a file (stability debounce + atomic rename to .processing). The fs watcher/scan and
 * job creation (via JobManager) live in DR4.1.
 */

const MAX_JOB_ID_LENGTH = 200;
const JOB_ID_PATTERN = /^[A-Za-z0-9][A-Za-z0-9_-]*$/;

const CYRILLIC_TO_LATIN: Readonly<Record<string, string>> = {
  а: "a", б: "b", в: "v", г: "g", д: "d", е: "e", ё: "e", ж: "zh", з: "z", и: "i",
  й: "y", к: "k", л: "l", м: "m", н: "n", о: "o", п: "p", р: "r", с: "s", т: "t",
  у: "u", ф: "f", х: "h", ц: "ts", ч: "ch", ш: "sh", щ: "shch", ъ: "", ы: "y", ь: "",
  э: "e", ю: "yu", я: "ya",
};

export const transliterate = (value: string): string =>
  Array.from(value).map((ch) => CYRILLIC_TO_LATIN[ch] ?? ch).join("");

/** Sanitize a filename stem into a job-id-safe token (mirrors the python watcher). */
export const sanitizeStem = (stem: string, maxLength: number): string => {
  const normalized = transliterate(stem.trim().toLowerCase());
  // Collapse any run of non-alphanumeric characters into a single separator.
  let sanitized = normalized.replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "");
  if (sanitized.length === 0) {
    const digest = createHash("sha1").update(stem, "utf-8").digest("hex").slice(0, 12);
    sanitized = `file-${digest}`;
  }
  if (sanitized.length > maxLength) {
    sanitized = sanitized.slice(0, maxLength).replace(/-+$/, "");
  }
  return sanitized.length === 0 ? "f" : sanitized;
};

export interface MediaJobIdOptions {
  readonly now?: number;
  readonly uuid?: string;
}

/**
 * Build `<ts>_<uuid>_<model>_<stem>` (getModelFromJobId resolves the model from the
 * slice after ts/uuid, so the uuid must not contain "_" — hyphens are stripped).
 */
export const buildMediaJobId = (
  modelName: string,
  originalFilename: string,
  options: MediaJobIdOptions = {},
): string => {
  const now = options.now ?? Date.now();
  const uuid = (options.uuid ?? crypto.randomUUID()).replace(/-/g, "");
  const prefix = `${now}_${uuid}_${modelName}`;
  const maxFilenameLength = MAX_JOB_ID_LENGTH - prefix.length - 1;
  if (maxFilenameLength <= 0) {
    throw new Error(`Model name cannot be used in job_id: ${modelName}`);
  }
  const stem = path.parse(originalFilename).name;
  const jobId = `${prefix}_${sanitizeStem(stem, maxFilenameLength)}`;
  if (jobId.length > MAX_JOB_ID_LENGTH || jobId.includes("..") || !JOB_ID_PATTERN.test(jobId)) {
    throw new Error(`Invalid job_id built: ${jobId}`);
  }
  return jobId;
};

const IGNORED_SUFFIXES = [".json", ".json.lock", ".processing", ".tmp", ".lock"];

/** A raw media file (not a queue marker, claim marker or dotfile). */
export const isProcessableMediaFile = (fileName: string): boolean => {
  const lower = fileName.toLowerCase();
  if (lower.startsWith(".")) {
    return false;
  }
  return !IGNORED_SUFFIXES.some((suffix) => lower.endsWith(suffix));
};

export interface ClaimDeps {
  stat: (filePath: string) => Promise<{ mtimeMs: number; isFile: () => boolean }>;
  rename: (from: string, to: string) => Promise<void>;
  now: () => number;
}

const defaultClaimDeps: ClaimDeps = { stat: fsStat, rename: fsRename, now: () => Date.now() };

export interface ClaimedMedia {
  readonly processingPath: string;
  readonly originalFilename: string;
}

/**
 * Claim a dropped file: skip it while it is still being written (mtime younger than
 * `stableMs` — a large copy keeps bumping mtime) and, once stable, atomically rename it
 * to `<name>.processing` so it is claimed exactly once and the input watcher ignores it.
 * Returns null if not a media file, not yet stable, gone, or lost the race.
 */
export const claimMediaFile = async (
  dir: string,
  fileName: string,
  stableMs: number,
  deps: ClaimDeps = defaultClaimDeps,
): Promise<ClaimedMedia | null> => {
  if (!isProcessableMediaFile(fileName)) {
    return null;
  }
  const src = path.join(dir, fileName);

  let stats: { mtimeMs: number; isFile: () => boolean };
  try {
    stats = await deps.stat(src);
  } catch {
    return null;
  }
  if (!stats.isFile() || deps.now() - stats.mtimeMs < stableMs) {
    return null; // gone/dir, or still being written
  }

  const processingPath = `${src}.processing`;
  try {
    await deps.rename(src, processingPath);
  } catch {
    return null; // already claimed / removed concurrently
  }
  return { processingPath, originalFilename: fileName };
};
