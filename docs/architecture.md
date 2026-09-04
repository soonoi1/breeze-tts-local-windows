# Architecture and runtime contract

## Data flow

```text
client / CCAgent
      │ HTTP multipart POST /v1/audio/speech
      ▼
Windows :9000  (deploy/windows/tcpproxy.py in WSL mode)
      │ dynamic WSL IPv4 target :7860
      ▼
WSL2 Ubuntu / native Windows
      │ breeze_infer.api
      ▼
Breeze TTS 2 checkpoint
      │ streaming mono PCM, 24 kHz, s16le
      ▼
client converts PCM to WAV or schedules it directly
```

The proxy resolves the WSL IP for each incoming connection, so a WSL2 IP change after reboot
does not require editing a hard-coded address. Its 10-second socket timeout applies only to
connection establishment; after connect it switches both sockets back to blocking mode so a
50-second lazy model reload cannot close an otherwise healthy request.

## Lifecycle

- On startup, `breeze_infer.api` loads tokenizer, Breeze model, bundled audio tokenizer, and
  optional CUDA-graph warmup.
- A single inference lease is allowed because the tested fast path is single-concurrency.
- `BREEZE_IDLE_TIMEOUT` defaults to 120 seconds. The watcher drops model state, calls garbage
  collection, and releases CUDA cache, but keeps the HTTP process alive.
- The next request performs an idempotent lazy reload in `asyncio.to_thread`; the HTTP event loop
  remains responsive while the model loads.
- A generation hard deadline (`BREEZE_GEN_TIMEOUT`, default 180 s) and no-audio stall limit
  (`BREEZE_GEN_STALL`, default 45 s) prevent a stuck generation from holding the lease forever.
- The request lease watchdog (`BREEZE_LOCK_TIMEOUT`, default 300 s) can recover a cancelled
  request. Lease owner ids ensure an old generator cannot release a newer request's lock.

## Mode selection

| Mode | API process | External port | Expected use |
| --- | --- | ---: | --- |
| WSL2 fast-all | Ubuntu `python -m breeze_infer.api ... --fast-all` | 9000 | RTX 4090-class real-time path |
| Native eager | Windows Python `... --no-fast-all` | 9000 | compatibility/batch fallback |

The model is not in Git. `scripts/download_model.py` obtains it from
`BreezeBlue/Breeze-TTS-2`; `scripts/patch_model_config.py` changes only attention settings in
the local checkpoint directory.

## API contract

`POST /v1/audio/speech` accepts multipart form fields:

- required: `text`
- optional: `instruction` (natural-language voice direction)
- optional: `cfg_scale` (positive float)
- optional: `seed` (integer)
- optional pair: `ref_audio` + `ref_text`

The response is a streaming body with:

- `Content-Type: audio/pcm`
- `X-Sample-Rate: 24000`
- `X-Sample-Format: s16le`

The API is intentionally single-concurrency and returns HTTP 409 while another synthesis is in
progress. The client should retry after the current stream finishes; it should not launch another
model process.

## Windows/WSL task model

`register-tasks.ps1` creates long-lived scheduled tasks with no execution time limit and
`IdleSettings.StopOnIdleEnd = $false`. This is required because starting a long-lived WSL process
from an SSH child can cause Windows OpenSSH job cleanup to terminate it. The scheduled task is the
persistence boundary.

## Files that must stay local

- `config/.env` or any other `.env`
- `secrets.json`, API credentials, TLS certificates/private keys
- model files (`*.safetensors`, `*.bin`, etc.)
- real reference recordings under `voices/`
- generated audio under `outputs/`
