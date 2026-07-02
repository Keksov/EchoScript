import { test, expect } from "bun:test";

import {
  transliterate,
  sanitizeStem,
  buildMediaJobId,
  isProcessableMediaFile,
  claimMediaFile,
  type ClaimDeps,
} from "./file-drop";
import { getModelFromJobId } from "./job-manager";

test("transliterate maps (lowercase) Cyrillic to Latin, leaves the rest", () => {
  expect(transliterate("два человека")).toBe("dva cheloveka");
  expect(transliterate("привет-мир")).toBe("privet-mir");
});

test("sanitizeStem normalizes, transliterates and bounds length", () => {
  expect(sanitizeStem("The Absolute", 100)).toBe("the-absolute");
  expect(sanitizeStem("Два человека", 100)).toBe("dva-cheloveka");
  expect(sanitizeStem("!!!", 100)).toMatch(/^file-[0-9a-f]{12}$/); // no latin chars -> hash
  expect(sanitizeStem("abcdefghij", 4)).toBe("abcd");
});

test("buildMediaJobId produces a valid, model-resolvable id", () => {
  const jobId = buildMediaJobId("whisper_podlodka", "CD4 - 8 - The Absolute.flac", {
    now: 1751000000000,
    uuid: "abc-def-123",
  });
  expect(jobId).toBe("1751000000000_abcdef123_whisper_podlodka_cd4-8-the-absolute");
  expect(getModelFromJobId(jobId, ["whisper_podlodka", "vosk_ru"])).toBe("whisper_podlodka");
});

test("buildMediaJobId handles a Cyrillic filename", () => {
  const jobId = buildMediaJobId("whisper_podlodka", "Два человека.wav", { now: 1, uuid: "u" });
  expect(jobId).toBe("1_u_whisper_podlodka_dva-cheloveka");
  expect(getModelFromJobId(jobId, ["whisper_podlodka"])).toBe("whisper_podlodka");
});

test("isProcessableMediaFile skips markers, temp and dotfiles", () => {
  expect(isProcessableMediaFile("song.flac")).toBe(true);
  expect(isProcessableMediaFile("1_a_m.json")).toBe(false);
  expect(isProcessableMediaFile("1_a_m.json.lock")).toBe(false);
  expect(isProcessableMediaFile("song.flac.processing")).toBe(false);
  expect(isProcessableMediaFile("x.tmp")).toBe(false);
  expect(isProcessableMediaFile(".hidden")).toBe(false);
});

const claimDeps = (
  mtimeMs: number,
  now: number,
  renamed: { from?: string; to?: string },
  isFileVal = true,
): ClaimDeps => ({
  stat: async () => ({ mtimeMs, isFile: () => isFileVal }),
  rename: async (from, to) => {
    renamed.from = from;
    renamed.to = to;
  },
  now: () => now,
});

test("claimMediaFile skips a file still being written (mtime too recent)", async () => {
  const renamed: { from?: string; to?: string } = {};
  const result = await claimMediaFile("/jobs/input/m", "big.flac", 2000, claimDeps(9000, 10000, renamed));
  expect(result).toBeNull(); // 10000 - 9000 = 1000 < 2000
  expect(renamed.from).toBeUndefined(); // no rename attempted
});

test("claimMediaFile claims a stable file via atomic rename to .processing", async () => {
  const renamed: { from?: string; to?: string } = {};
  const result = await claimMediaFile("/jobs/input/m", "big.flac", 2000, claimDeps(1000, 10000, renamed));
  expect(result?.originalFilename).toBe("big.flac");
  expect(result?.processingPath.endsWith("big.flac.processing")).toBe(true);
  expect(renamed.to?.endsWith("big.flac.processing")).toBe(true);
});

test("claimMediaFile returns null for a non-media file without statting", async () => {
  const renamed: { from?: string; to?: string } = {};
  const result = await claimMediaFile("/jobs/input/m", "note.json", 2000, claimDeps(1, 10000, renamed));
  expect(result).toBeNull();
});
