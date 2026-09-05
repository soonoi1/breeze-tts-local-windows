"""Thin streaming API over the PyTorch Breeze inference runtime.

Modified for idle offload: model unloads from GPU after BREEZE_IDLE_TIMEOUT
seconds of inactivity, and lazily reloads on the next request.
"""

from __future__ import annotations

import argparse
import asyncio
import gc
import os
import tempfile
import threading
import time
import uuid
from collections.abc import AsyncIterator, Iterator
from contextlib import asynccontextmanager
from dataclasses import dataclass, replace
from pathlib import Path

import numpy as np
import torch
from fastapi import FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import JSONResponse, StreamingResponse

from breeze_infer.runtime import (
    load_runtime,
    resolve_device,
    set_all_seeds,
    update_generation_config_for_breeze,
)
from breeze_infer.templates import get_template, prepare_inputs
from models.fast_streaming import FastBreezeStreamingRuntime, FastStreamingConfig
from models.warmup_profile import load_warmup_profile

REPO_ROOT = Path(__file__).resolve().parents[1]
FAST_CONFIG = REPO_ROOT / "configs" / "fast.json"
DEFAULT_CFG_SCALE = 1.0
MAX_NEW_TOKENS = 1500
MAX_SEQ_LEN = 2048
REPETITION_PENALTY = 1.1
OPTIONAL_AUDIO_FILE = File(None)

# --- idle offload: unload GPU model after this many idle seconds ---
_IDLE_TIMEOUT = float(os.environ.get("BREEZE_IDLE_TIMEOUT", "120"))
_WATCH_INTERVAL = max(5.0, _IDLE_TIMEOUT / 8.0)
_last_activity = time.time()


@dataclass(frozen=True)
class ApiSettings:
    model: Path
    fast_all: bool | None
    fast_text_encoder: bool
    fast_backbone_prefill: bool
    fast_backbone_decode: bool
    fast_depth_decoder: bool
    fast_codec: bool


_settings: ApiSettings | None = None
_request_lock = threading.Lock()
_request_meta_lock = threading.Lock()
_request_lease_id = 0
_active_request_lease: int | None = None
_request_started_at: float | None = None


def _try_acquire_request() -> int | None:
    """Acquire the single-inference lease and return its owner id."""
    global _request_lease_id, _active_request_lease, _request_started_at
    if not _request_lock.acquire(blocking=False):
        return None
    with _request_meta_lock:
        _request_lease_id += 1
        _active_request_lease = _request_lease_id
        _request_started_at = time.monotonic()
        return _active_request_lease


def _release_request(lease: int | None) -> None:
    """Release only if this caller still owns the lease.

    The identity check matters when the watchdog had to recover a stale request
    and a newer request has already acquired the lock.
    """
    global _active_request_lease, _request_started_at
    if lease is None:
        return
    with _request_meta_lock:
        if _active_request_lease != lease:
            return
        _active_request_lease = None
        _request_started_at = None
        _request_lock.release()


def _force_release_stale_request() -> bool:
    """Recover a genuinely stale lease without stealing a newer one."""
    global _active_request_lease, _request_started_at
    with _request_meta_lock:
        if _active_request_lease is None or not _request_lock.locked():
            return False
        _active_request_lease = None
        _request_started_at = None
        _request_lock.release()
        return True


def _pcm16(audio: np.ndarray) -> bytes:
    audio = np.asarray(audio, dtype=np.float32)
    audio = np.clip(audio, -1.0, 1.0)
    return (audio * 32767.0).astype("<i2", copy=False).tobytes()


async def _save_upload(upload: UploadFile) -> Path:
    suffix = Path(upload.filename or "reference.wav").suffix or ".wav"
    with tempfile.NamedTemporaryFile(
        prefix="breeze_ref_", suffix=suffix, delete=False
    ) as temporary:
        path = Path(temporary.name)
        try:
            payload = await upload.read()
            if not payload:
                raise HTTPException(status_code=400, detail="Reference audio is empty.")
            temporary.write(payload)
        except Exception:
            path.unlink(missing_ok=True)
            raise
    return path


def _load_app(app: FastAPI, settings: ApiSettings) -> None:
    global _last_activity
    _set_load_progress(5, "loading tokenizer")
    tokenizer, model, audio_tokenizer = load_runtime(
        settings.model,
        device=resolve_device(),
        attn_implementation="eager",
    )
    update_generation_config_for_breeze(model)

    _set_load_progress(50, "building fast runtime")
    config = FastStreamingConfig(
        max_new_tokens=MAX_NEW_TOKENS,
        max_seq_len=MAX_SEQ_LEN,
        fast_all=settings.fast_all,
        fast_text_encoder=settings.fast_text_encoder,
        fast_backbone_prefill=settings.fast_backbone_prefill,
        fast_backbone_decode=settings.fast_backbone_decode,
        fast_depth_decoder=settings.fast_depth_decoder,
        fast_codec=settings.fast_codec,
        repetition_penalty=REPETITION_PENALTY,
    )
    runtime = FastBreezeStreamingRuntime(
        model, audio_tokenizer, config, tokenizer=tokenizer
    )
    if runtime.fast_enabled:
        _set_load_progress(65, "capturing cuda graphs")
        profile = load_warmup_profile(FAST_CONFIG)
        profile = replace(profile, codec_chunk_frames=runtime.codec_chunk_frames)
        manifest = runtime.warmup_from_profile(profile)
        print(f"fast warmup: {manifest['total_elapsed_ms']:.2f} ms", flush=True)

    app.state.tokenizer = tokenizer
    app.state.model = model
    app.state.audio_tokenizer = audio_tokenizer
    app.state.runtime = runtime
    _set_load_progress(100, "ready")
    # Loading takes tens of seconds; reset the idle clock so the watcher
    # does not immediately unload a freshly-loaded model.
    _last_activity = time.time()


# --- load progress (thread-safe, read by /health) ---
_load_progress_lock = threading.Lock()
_load_progress = {"progress": 0, "stage": "idle"}


def _set_load_progress(progress: int, stage: str) -> None:
    with _load_progress_lock:
        _load_progress["progress"] = progress
        _load_progress["stage"] = stage
    print(f"[load] {progress}% {stage}", flush=True)


def _get_load_progress() -> tuple[int, str]:
    with _load_progress_lock:
        return _load_progress["progress"], _load_progress["stage"]


_load_thread_lock = threading.Lock()


def _ensure_loaded(app: FastAPI) -> None:
    """Lazily (re)load the model if it was idle-offloaded (blocking, run in a thread)."""
    if hasattr(app.state, "runtime"):
        return
    with _load_thread_lock:
        if hasattr(app.state, "runtime"):
            return
        print("[lazy] model idle-offloaded, reloading on demand...", flush=True)
        t0 = time.time()
        _load_app(app, _settings)
        print(f"[lazy] model reloaded in {time.time() - t0:.1f}s", flush=True)


async def ensure_loaded_async(app: FastAPI) -> None:
    """Threaded lazy load so the event loop stays responsive while the model
    reloads (~40-50s). Without this, uvicorn freezes, the TCP accept queue
    fills, and every client through the port forwarder gets dropped.

    Note: if the client disconnects mid-reload, uvicorn cancels this coroutine
    (CancelledError). The worker thread keeps loading and the threading lock
    guarantees a single loader; the caller is responsible for releasing the
    request lock via except BaseException (see speech endpoint)."""
    if hasattr(app.state, "runtime"):
        return
    await asyncio.to_thread(_ensure_loaded, app)


def _unload_app(app: FastAPI) -> None:
    """Drop all model state and release GPU memory (keeps the process alive)."""
    for attr in ("runtime", "model", "audio_tokenizer", "tokenizer"):
        if hasattr(app.state, attr):
            try:
                delattr(app.state, attr)
            except Exception:
                pass
    # Reset progress so the next cold start reports real stages instead of the
    # stale "100 ready" from the previous load (clients poll /health while
    # status says loading and would show a full ring jumping back to 5%).
    with _load_progress_lock:
        _load_progress["progress"] = 0
        _load_progress["stage"] = "idle"
    gc.collect()
    if torch.cuda.is_available():
        torch.cuda.empty_cache()
        torch.cuda.synchronize()
        memory = torch.cuda.memory_allocated() / 1e6
    else:
        memory = 0
    print(f"[idle] GPU memory after unload: {memory:.0f} MB", flush=True)


async def _idle_watcher(app: FastAPI) -> None:
    """Background task: unload the model when the API has been idle too long,
    and force-release the request lock if a request leaked it (client
    disconnect during lazy reload used to wedge the service with 409s)."""
    global _last_activity
    while True:
        await asyncio.sleep(_WATCH_INTERVAL)
        try:
            # Leak guard: recover only a lease that has exceeded the configured
            # maximum. The lease id prevents an old generator's finally block
            # from releasing a newer request's lock.
            with _request_meta_lock:
                lease = _active_request_lease
                started_at = _request_started_at
            lock_timeout = float(os.environ.get("BREEZE_LOCK_TIMEOUT", "300"))
            if (
                lease is not None
                and started_at is not None
                and time.monotonic() - started_at > lock_timeout
                and _force_release_stale_request()
            ):
                print(
                    f"[watchdog] request lease exceeded {lock_timeout:.0f}s, forcing release",
                    flush=True,
                )

            if hasattr(app.state, "runtime") and not _request_lock.locked():
                idle_for = time.time() - _last_activity
                if idle_for >= _IDLE_TIMEOUT:
                    print(
                        f"[idle] unloading model after {idle_for:.0f}s idle "
                        f"(timeout {_IDLE_TIMEOUT:.0f}s)",
                        flush=True,
                    )
                    _unload_app(app)
        except Exception as exc:  # pragma: no cover - defensive
            print(f"[idle] watcher error: {exc}", flush=True)


@asynccontextmanager
async def _lifespan(app: FastAPI) -> AsyncIterator[None]:
    if _settings is None:
        raise RuntimeError("API settings are not initialized")
    _load_app(app, _settings)
    watcher = asyncio.create_task(_idle_watcher(app))
    yield
    watcher.cancel()
    try:
        await watcher
    except asyncio.CancelledError:
        pass


app = FastAPI(title="Breeze TTS API", lifespan=_lifespan)


@app.post("/warm")
async def warm() -> JSONResponse:
    """Start the lazy load immediately without waiting for a synthesis.

    Fire-and-forget warm kick used by clients when a voice session opens: the
    load runs in a daemon thread (ensure_loaded_async) and this returns at once.
    """
    if hasattr(app.state, "runtime"):
        return JSONResponse({"status": "ok", "progress": 100, "stage": "ready"})
    global _last_activity
    _last_activity = time.time()
    asyncio.get_event_loop().create_task(ensure_loaded_async_wrapper())
    return JSONResponse({"status": "loading", "progress": _get_load_progress()[0], "stage": _get_load_progress()[1]}, status_code=202)


async def ensure_loaded_async_wrapper() -> None:
    try:
        await ensure_loaded_async(app)
    except BaseException as exc:  # daemon task: never propagate
        print(f"[warm] background load failed: {exc}", flush=True)


@app.get("/health")
def health() -> JSONResponse:
    if not hasattr(app.state, "runtime"):
        progress, stage = _get_load_progress()
        return JSONResponse(
            {
                "status": "loading",
                "model": "idle",
                "progress": progress if progress > 0 else 0,
                "stage": stage,
            },
            status_code=503,
        )
    return JSONResponse(
        {
            "status": "ok",
            "sample_rate": app.state.runtime.sample_rate,
            "model": "loaded",
            "progress": 100,
            "stage": "ready",
        }
    )


@app.post("/v1/audio/speech")
async def speech(
    request: Request,
    text: str = Form(...),
    instruction: str = Form("Speak clearly and naturally."),
    cfg_scale: float = Form(DEFAULT_CFG_SCALE),
    ref_audio: UploadFile | None = OPTIONAL_AUDIO_FILE,
    ref_text: str = Form(""),
    seed: int = Form(42),
) -> StreamingResponse:
    global _last_activity
    _last_activity = time.time()

    lease = _try_acquire_request()
    if lease is None:
        raise HTTPException(
            status_code=409, detail="An inference request is already running."
        )

    reference_path: Path | None = None
    try:
        await ensure_loaded_async(app)

        # The client may have disconnected during the long lazy reload. If so,
        # bail out and release the lock instead of streaming into the void
        # (the sync generator cannot be force-closed while parked on a yield,
        # which used to leak the lock and wedge the service with 409s).
        if await request.is_disconnected():
            print("[lazy] client disconnected during reload, releasing lock", flush=True)
            _release_request(lease)
            return StreamingResponse(iter(()), media_type="audio/pcm")

        if not np.isfinite(cfg_scale) or cfg_scale <= 0:
            raise HTTPException(
                status_code=400, detail="cfg_scale must be greater than 0."
            )
        ref_text = ref_text.strip()
        has_reference = ref_audio is not None and bool(ref_audio.filename)
        if has_reference != bool(ref_text):
            raise HTTPException(
                status_code=400,
                detail="ref_audio and ref_text must be provided together or both omitted.",
            )
        if has_reference:
            assert ref_audio is not None
            reference_path = await _save_upload(ref_audio)

        request_id = f"api-{uuid.uuid4().hex}"
        request = {
            "id": request_id,
            "text": text,
            "instruction": instruction,
            "speaker": "S0",
        }
        template_name = "tts_instruction"
        if reference_path is not None:
            request["ref_audio_path"] = str(reference_path)
            request["ref_text"] = ref_text
            template_name = "ref_edit_tata"

        set_all_seeds(seed)
        inputs = prepare_inputs(
            app.state.tokenizer,
            app.state.audio_tokenizer,
            app.state.model,
            [request],
            get_template(template_name),
            guidance_scale=cfg_scale,
            guidance_scale_ref=None,
            guidance_scale_ins=None,
        )
    except BaseException:
        # BaseException (not just Exception): uvicorn cancels this coroutine
        # with CancelledError when the client disconnects mid-reload; the
        # request lock must still be released or every later request gets 409.
        if reference_path is not None:
            reference_path.unlink(missing_ok=True)
        _release_request(lease)
        raise

    def body() -> Iterator[bytes]:
        # Watchdog: abort a generation that stalls or runs away so the single
        # request lock is never held forever (long generations previously
        # wedged the whole service with 409 for every later request).
        started_at = time.monotonic()
        last_yield_at = started_at
        hard_deadline = float(os.environ.get("BREEZE_GEN_TIMEOUT", "180"))
        stall_limit = float(os.environ.get("BREEZE_GEN_STALL", "45"))
        try:
            for chunk in app.state.runtime.iter_audio_chunks(
                inputs, request_id=request_id
            ):
                now = time.monotonic()
                if now - last_yield_at > stall_limit:
                    print(
                        f"[watchdog] no audio for {now - last_yield_at:.0f}s, aborting",
                        flush=True,
                    )
                    break
                if now - started_at > hard_deadline:
                    print(
                        f"[watchdog] generation exceeded {hard_deadline:.0f}s, aborting",
                        flush=True,
                    )
                    break
                last_yield_at = now
                pcm = _pcm16(chunk.audio)
                if pcm:
                    yield pcm
        finally:
            if reference_path is not None:
                reference_path.unlink(missing_ok=True)
            _release_request(lease)

    return StreamingResponse(
        body(),
        media_type="audio/pcm",
        headers={
            "X-Sample-Rate": str(app.state.runtime.sample_rate),
            "X-Sample-Format": "s16le",
            "Cache-Control": "no-store",
        },
    )


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Serve Breeze TTS 2 streaming inference"
    )
    parser.add_argument("model", type=Path)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=7860)
    parser.add_argument(
        "--fast-all", action=argparse.BooleanOptionalAction, default=None
    )
    parser.add_argument(
        "--fast-text-encoder", action=argparse.BooleanOptionalAction, default=False
    )
    parser.add_argument(
        "--fast-backbone-prefill", action=argparse.BooleanOptionalAction, default=False
    )
    parser.add_argument(
        "--fast-backbone-decode", action=argparse.BooleanOptionalAction, default=False
    )
    parser.add_argument(
        "--fast-depth-decoder", action=argparse.BooleanOptionalAction, default=False
    )
    parser.add_argument(
        "--fast-codec", action=argparse.BooleanOptionalAction, default=False
    )
    args = parser.parse_args()

    global _settings
    _settings = ApiSettings(
        model=args.model,
        fast_all=args.fast_all,
        fast_text_encoder=args.fast_text_encoder,
        fast_backbone_prefill=args.fast_backbone_prefill,
        fast_backbone_decode=args.fast_backbone_decode,
        fast_depth_decoder=args.fast_depth_decoder,
        fast_codec=args.fast_codec,
    )

    import uvicorn

    uvicorn.run(app, host=args.host, port=args.port, log_level="info")


if __name__ == "__main__":
    main()
