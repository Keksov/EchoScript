import { test, expect } from "bun:test";
import { tmpdir } from "node:os";
import path from "node:path";
import { mkdtemp, mkdir, rm, writeFile, readFile, stat } from "node:fs/promises";

import { loadConfig } from "./config";
import { JobManager, getModelFromJobId } from "./job-manager";

const JOBS_ROOT_ENV = "ECHOSCRIPT_JOBS_ROOT";

/** Load config against a throwaway jobs root, restoring the env var immediately. */
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

const seedJob = async (
  jm: JobManager,
  jobId: string,
  files: Record<string, unknown>,
): Promise<void> => {
  const dataDir = jm.getDataDir(jobId);
  await mkdir(dataDir, { recursive: true });
  for (const [name, payload] of Object.entries(files)) {
    await writeFile(path.join(dataDir, name), `${JSON.stringify(payload, null, 2)}\n`, "utf-8");
  }
};

test("listJobs surfaces per-job progress from progress.json", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "jm-progress-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const jobId = "1700000000000_abcdef_whisper_podlodka";
    await seedJob(jm, jobId, {
      "input.json": { source: "input", original_filename: "big.wav", created_from: "file_drop" },
      "status.json": [{ status: "processing", updated_at: "2026-07-01T00:00:00.000Z" }],
      "progress.json": {
        progress_pct: 42,
        windows_done: 5,
        windows_total: 12,
        processed_ms: 126000,
        total_ms: 300000,
        updated_at: "2026-07-01T00:01:00.000Z",
      },
    });

    const jobs = await jm.listJobs();
    const listed = jobs.find((j) => j.job_id === jobId);
    expect(listed).toBeDefined();
    expect(listed?.progress).not.toBeNull();
    expect(listed?.progress?.progress_pct).toBe(42);
    expect(listed?.progress?.windows_done).toBe(5);
    expect(listed?.progress?.windows_total).toBe(12);
    expect(listed?.progress?.total_ms).toBe(300000);
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("countJobStatus counts prior states and markFailed writes failed + output marker", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "jm-cap-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const jobId = "1700000000020_cccccc_whisper_podlodka";
    await seedJob(jm, jobId, {
      "status.json": [
        { status: "waiting", updated_at: "t1" },
        { status: "pending", updated_at: "t2" },
        { status: "waiting", updated_at: "t3" },
      ],
    });

    expect(await jm.countJobStatus(jobId, "waiting")).toBe(2);
    expect(await jm.countJobStatus(jobId, "processing")).toBe(0);

    await jm.markFailed(jobId, "boom after cap");
    const statuses = JSON.parse(await readFile(path.join(base, "data", jobId, "status.json"), "utf-8"));
    const last = statuses[statuses.length - 1];
    expect(last.status).toBe("failed");
    expect(last.error).toBe("boom after cap");
    const marker = JSON.parse(await readFile(path.join(base, "output", `${jobId}.json`), "utf-8"));
    expect(marker.status).toBe("failed");
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("createDroppedJob moves the file into data/<id>/input and writes drop artifacts", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "jm-drop-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    // a claimed drop file sitting as <name>.processing
    const processingPath = path.join(base, "Два человека.wav.processing");
    await writeFile(processingPath, Buffer.alloc(16, 7));

    const created = await jm.createDroppedJob(processingPath, "Два человека.wav", "whisper_podlodka");
    expect(getModelFromJobId(created.jobId, Object.keys(config.models))).toBe("whisper_podlodka");

    // file moved into the job's data dir; original .processing is gone
    const moved = await readFile(path.join(created.dataDir, "input"));
    expect(moved.length).toBe(16);
    await expect(stat(processingPath)).rejects.toBeDefined();

    const inputJson = JSON.parse(await readFile(path.join(created.dataDir, "input.json"), "utf-8"));
    expect(inputJson.source).toBe("input");
    expect(inputJson.original_filename).toBe("Два человека.wav");
    expect(inputJson.created_from).toBe("file_drop");

    // status.json exists (initial lifecycle) and enqueue then drops a queue marker
    expect(JSON.parse(await readFile(path.join(created.dataDir, "status.json"), "utf-8")).length).toBeGreaterThan(0);
    await jm.enqueueJob(created.jobId, {});
    await stat(path.join(base, "queue", `${created.jobId}.json`)); // throws if missing
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});

test("getJobProgress returns the progress object, or null when absent", async () => {
  const base = await mkdtemp(path.join(tmpdir(), "jm-progress2-"));
  try {
    const config = await configWithJobsRoot(base);
    const jm = new JobManager(config);
    await jm.initialize();

    const withProgress = "1700000000010_aaaaaa_whisper_podlodka";
    await seedJob(jm, withProgress, {
      "progress.json": {
        progress_pct: 100,
        windows_done: 12,
        windows_total: 12,
        processed_ms: 300000,
        total_ms: 300000,
        updated_at: "2026-07-01T00:05:00.000Z",
      },
    });

    const progress = await jm.getJobProgress(withProgress);
    expect(progress?.progress_pct).toBe(100);
    expect(progress?.windows_done).toBe(12);

    // An existing job dir with no progress.json yet yields null (not an error).
    const noProgressId = "1700000000011_bbbbbb_whisper_podlodka";
    await seedJob(jm, noProgressId, {});
    const missing = await jm.getJobProgress(noProgressId);
    expect(missing).toBeNull();
  } finally {
    await rm(base, { recursive: true, force: true });
  }
});
