import { statSync } from "node:fs"
import { join } from "node:path"

import { repoRoot } from "./config"

/**
 * Model/asset inventory for the Models tab. Covers everything the recognition stack uses,
 * with its provisioning method:
 *  - downloadable via a script (whisper en/turbo, Silero VAD, diarization assets)
 *  - non-downloadable, staged by a local conversion (whisper_podlodka RU) — shown read-only.
 * Paths are repo-relative; a model counts as present only when all its files exist.
 */
interface ModelEntry {
  readonly id: string
  readonly model: string
  readonly kind: "language" | "vad" | "diarization"
  readonly files: readonly string[]
  readonly download?: { readonly script: string; readonly args: readonly string[] }
  /** How to provision when not script-downloadable (shown as a hint). */
  readonly note?: string
}

const WHISPER_DL = "services/whisperdaemon/scripts/download_whisper_models.bat"
const DIARIZE_DL = "services/whisperdaemon/scripts/download_diarize_models.bat"

const MANIFEST: readonly ModelEntry[] = [
  {
    id: "podlodka",
    model: "whisper_podlodka (ru)",
    kind: "language",
    files: ["services/whisperdaemon/models/ggml-whisper_podlodka.bin"],
    note: "convert_whisper_podlodka_hf_to_ggml.bat + stage_whisperdaemon_model.bat",
  },
  {
    id: "en",
    model: "whisper_en_turbo (en)",
    kind: "language",
    files: ["services/whisperdaemon/models/ggml-whisper_en_turbo.bin"],
    download: { script: WHISPER_DL, args: ["en"] },
  },
  {
    id: "vad",
    model: "silero-v5.1.2 (VAD)",
    kind: "vad",
    files: ["services/whisperdaemon/models/ggml-silero-v5.1.2.bin"],
    download: { script: WHISPER_DL, args: ["vad"] },
  },
  {
    id: "diarization",
    model: "diarizationdaemon (sherpa)",
    kind: "diarization",
    files: [
      "services/whisperdaemon/models/diarization/segmentation.onnx",
      "services/whisperdaemon/models/diarization/embedding.onnx",
      "services/whisperdaemon/vendors/sherpa-onnx/sherpa-onnx.dll",
    ],
    download: { script: DIARIZE_DL, args: [] },
  },
]

/** ids currently downloading (module state — the control-server is a single process). */
const inProgress = new Set<string>()

export interface ModelStatus {
  readonly id: string
  readonly model: string
  readonly kind: "language" | "vad" | "diarization"
  readonly downloadable: boolean
  readonly downloaded: boolean
  readonly sizeMb: number | null
  readonly downloading: boolean
  readonly note: string | null
  /** Absolute paths of this model's file(s). */
  readonly paths: string[]
}

export const listModels = (): ModelStatus[] =>
  MANIFEST.map((entry) => {
    let present = 0
    let bytes = 0
    for (const file of entry.files) {
      try {
        const stat = statSync(join(repoRoot, file))
        if (stat.isFile() && stat.size > 0) {
          present += 1
          bytes += stat.size
        }
      } catch {
        // missing
      }
    }
    const downloaded = present === entry.files.length && entry.files.length > 0
    if (downloaded && inProgress.has(entry.id)) {
      inProgress.delete(entry.id)
    }
    return {
      id: entry.id,
      model: entry.model,
      kind: entry.kind,
      downloadable: entry.download !== undefined,
      downloaded,
      sizeMb: bytes > 0 ? Math.round((bytes / 1024 / 1024) * 10) / 10 : null,
      downloading: inProgress.has(entry.id),
      note: entry.note ?? null,
      paths: entry.files.map((file) => join(repoRoot, file)),
    }
  })

/**
 * Kick off a model download in the background via Bun.spawn (see services-control for the
 * Windows socket-inheritance note). The scripts are idempotent; the `downloading` flag clears
 * when the files appear (listModels) or via a backstop timeout. Non-downloadable models
 * (locally converted) are rejected.
 */
export const startDownload = (id: string): { started: boolean; reason?: string } => {
  const entry = MANIFEST.find((item) => item.id === id)
  if (entry === undefined) {
    return { started: false, reason: "unknown model id" }
  }
  if (entry.download === undefined) {
    return { started: false, reason: "not script-downloadable (staged via a conversion script)" }
  }
  if (inProgress.has(id)) {
    return { started: false, reason: "already downloading" }
  }
  inProgress.add(id)
  const proc = Bun.spawn(["cmd", "/c", join(repoRoot, entry.download.script), ...entry.download.args], {
    cwd: repoRoot,
    stdio: ["ignore", "ignore", "ignore"],
  })
  void proc.exited.then(() => inProgress.delete(id)).catch(() => inProgress.delete(id))
  setTimeout(() => inProgress.delete(id), 15 * 60 * 1000).unref()
  return { started: true }
}
