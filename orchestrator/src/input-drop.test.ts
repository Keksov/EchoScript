import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, rm, writeFile, readFile, stat } from "node:fs/promises";

import { loadConfig } from "./config";
import { JobManager, getModelFromJobId } from "./job-manager";
import { scanInputDrops } from "./input-drop";

const JOBS_ROOT_ENV = "ECHOSCRIPT_JOBS_ROOT";

const configWithJobsRoot = async (jobsRoot: string) => {
  const previous = process.env[JOBS_ROOT_ENV];
  process.env[JOBS_ROOT_ENV] = jobsRoot;
  try {
    return await loadConfig();
  } finally {
    if (previous === undefined) delete process.env[JOBS_ROOT_ENV];
    else process.env[JOBS_ROOT_ENV] = previous;
  }
};

const inputDir = (base: string, model: string): string => path.join(base, "input", model);

test("scanInputDrops turns a dropped raw file into a queued job and consumes it", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-scan-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const dropped = path.join(inputDir(base, "whisper_podlodka"), "Два человека.wav");
    await writeFile(dropped, Buffer.alloc(32, 5));

    const created = await scanInputDrops(base, Object.keys(config.models), 0, jm);
    expect(created.length).toBe(1);
    const jobId = created[0]!;
    expect(getModelFromJobId(jobId, Object.keys(config.models))).toBe("whisper_podlodka");

    // raw file consumed, job data + queue marker created
    await expect(stat(dropped)).rejects.toBeDefined();
    expect((await readFile(path.join(base, "data", jobId, "input"))).length).toBe(32);
    await stat(path.join(base, "queue", `${jobId}.json`)); // throws if missing
    const inputJson = JSON.parse(await readFile(path.join(base, "data", jobId, "input.json"), "utf-8"));
    expect(inputJson.created_from).toBe("file_drop");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops recovers an orphaned .processing claim", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-orphan-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const orphan = path.join(inputDir(base, "whisper_podlodka"), "song.flac.processing");
    await writeFile(orphan, Buffer.alloc(8, 1));

    const created = await scanInputDrops(base, Object.keys(config.models), 0, jm);
    expect(created.length).toBe(1);
    await expect(stat(orphan)).rejects.toBeDefined(); // recovered/moved
    expect((await readFile(path.join(base, "data", created[0]!, "input"))).length).toBe(8);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("scanInputDrops ignores dispatch markers and unstable files", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "drop-skip-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const dir = inputDir(base, "whisper_podlodka");
    await writeFile(path.join(dir, "1751_abc_whisper_podlodka.json"), "{}"); // dispatch marker
    await writeFile(path.join(dir, "fresh.flac"), Buffer.alloc(4)); // just written -> unstable

    // stableMs high so the fresh file is not yet claimable; marker never claimable
    const created = await scanInputDrops(base, Object.keys(config.models), 60000, jm);
    expect(created).toEqual([]);
    await stat(path.join(dir, "1751_abc_whisper_podlodka.json")); // marker untouched
    await stat(path.join(dir, "fresh.flac")); // still there (unstable)
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
