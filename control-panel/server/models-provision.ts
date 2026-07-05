import { statSync } from "node:fs"
import { join } from "node:path"

import { repoRoot } from "./config"

/** Downloadable whisper assets, mirroring services/whisperdaemon/scripts/download_whisper_models.bat. */
interface ModelEntry {
  readonly id: string
  readonly model: string
  readonly file: string
  readonly kind: "language" | "vad"
}

const MANIFEST: readonly ModelEntry[] = [
  { id: "en", model: "whisper_en_turbo", file: "ggml-whisper_en_turbo.bin", kind: "language" },
  { id: "vad", model: "silero-v5.1.2", file: "ggml-silero-v5.1.2.bin", kind: "vad" },
]

const modelsDir = join(repoRoot, "services", "whisperdaemon", "models")
const downloadScript = "services/whisperdaemon/scripts/download_whisper_models.bat"

/** ids currently downloading (module state — the control-server is a single process). */
const inProgress = new Set<string>()

export interface ModelStatus extends ModelEntry {
  readonly downloaded: boolean
  readonly sizeMb: number | null
  readonly downloading: boolean
}

export const listModels = (): ModelStatus[] =>
  MANIFEST.map((entry) => {
    let downloaded = false
    let sizeMb: number | null = null
    try {
      const stat = statSync(join(modelsDir, entry.file))
      downloaded = stat.isFile() && stat.size > 0
      sizeMb = downloaded ? Math.round((stat.size / 1024 / 1024) * 10) / 10 : null
    } catch {
      // not present
    }
    // Self-heal the flag: once the file is present the download is done.
    if (downloaded && inProgress.has(entry.id)) {
      inProgress.delete(entry.id)
    }
    return { ...entry, downloaded, sizeMb, downloading: inProgress.has(entry.id) }
  })

/**
 * Kick off a model download in the background: launched via `cmd /c start "" /b` so the
 * download does not inherit the control-server's listening socket (see services-control).
 * The script is idempotent (skips if present); the `downloading` flag is cleared when the
 * file appears (listModels) or by a backstop timeout.
 */
export const startDownload = (id: string): { started: boolean; reason?: string } => {
  if (!MANIFEST.some((entry) => entry.id === id)) {
    return { started: false, reason: "unknown model id" }
  }
  if (inProgress.has(id)) {
    return { started: false, reason: "already downloading" }
  }
  inProgress.add(id)
  const proc = Bun.spawn(["cmd", "/c", join(repoRoot, downloadScript), id], {
    cwd: repoRoot,
    stdio: ["ignore", "ignore", "ignore"],
  })
  void proc.exited.then(() => inProgress.delete(id)).catch(() => inProgress.delete(id))
  setTimeout(() => inProgress.delete(id), 15 * 60 * 1000).unref()
  return { started: true }
}
