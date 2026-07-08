# diarizationdaemon (sherpa)

Speaker **diarization** daemon — segments audio by *who* is speaking (via sherpa-onnx:
a segmentation ONNX + a speaker-embedding ONNX, clustered). It is a WebSocket daemon in the
EchoScript fleet, managed like whisper/vosk through **echoctl** and the **control panel**.

The daemon itself (`sherpa/`) is a FPC binary (`sherpa/build/x64/DiarizationDaemon.exe`). This
README covers how it is *managed*; for building the binary see `sherpa/scripts/`.

## Engine model

Diarization is an **engine umbrella**: the engine is `diarization`, and its (currently only)
model is **`diarization_sherpa`** — the sherpa-onnx backend. Future backends would appear as
more `diarization_*` models under the same engine (mirrors `whisper_*` / `vosk_*`).

- **Ports** auto-allocate in **7900–7999** (whisper 78xx, vosk 77xx, diarization 79xx).
- **Model**: `diarization_sherpa` (in `echoctl/models-manifest.json`, `kind: diarization`).
  The daemon takes no `--model-name`; the ONNX models + sherpa runtime are located for it.
- **Readiness**: the daemon logs `warmup ready` once loaded (same marker as the other engines).
- **Language-agnostic**: no `language` needed.

## Manage via echoctl

```bat
echoctl daemons add --engine diarization --model diarization_sherpa --name diarization
echoctl daemons start diarization
echoctl daemons stop  diarization
echoctl daemons edit  diarization --set cluster_threshold=0.6 --set num_speakers=2
```

Tunable `settings` (per instance, applied as `DIARIZE_*` env at start):

| key | type | range | default | meaning |
|-----|------|-------|---------|---------|
| `num_speakers` | int | -1..64 | -1 | fixed speaker count; -1 = auto-detect |
| `cluster_threshold` | float | 0..1 | 0.5 | higher merges more voices into one speaker |
| `min_duration_on` | float | 0..10 | 0.2 | min active-speech segment length (s) |
| `min_duration_off` | float | 0..10 | 0.5 | min silence gap between segments (s) |

## Manage via the control panel

In the fleet form: pick engine **diarization**, model **diarization_sherpa** (the language
field is hidden — diarization is language-agnostic), optionally expand **Settings** for the
tuning above, and Save. Start/stop from the fleet list. In dev (`ECHOSCRIPT_DEV=1`), starting a
daemon also opens an `echotail` tab following its log.

## Runtime notes

- echoctl passes the sherpa runtime + models via env: `SHERPA_DLL_PATH`,
  `DIARIZE_SEG_MODEL`, `DIARIZE_EMB_MODEL` (under `sherpa/vendors/sherpa-onnx` and
  `sherpa/models`).
- sherpa-onnx loads the ONNX Runtime DLLs from the **exe directory**, so echoctl **stages**
  `onnxruntime.dll` + `onnxruntime_providers_shared.dll` from `sherpa/vendors/sherpa-onnx`
  into `sherpa/build/x64` before start (if missing).
- Assets are fetched by `sherpa/scripts/download_sherpa_assets.bat` (the manifest's download
  script for the diarization model).
