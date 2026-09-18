#!/usr/bin/env bash
# Launch the installed Breeze API inside WSL2.
#
# Idempotent: if the API is already healthy on the target port this exits 0
# without starting a second instance. The port is probed before launch so a
# stale listener is reported instead of silently failing in the log file.
set -Eeuo pipefail

DATA_DIR="${BREEZE_DATA_DIR:-/opt/breeze-tts-data}"
ENV_FILE="$DATA_DIR/breeze.env"
if [[ -f "$ENV_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$ENV_FILE"
fi

REPO_DIR="${BREEZE_REPO_DIR:-/opt/breeze-tts-local-windows}"
VENV_DIR="${BREEZE_VENV:-/opt/breeze-tts-venv}"
MODEL_DIR="${BREEZE_MODEL_DIR:-$DATA_DIR/models/Breeze-TTS-2}"
PORT="${BREEZE_PORT:-7860}"
FAST_MODE="${BREEZE_FAST_MODE:-fast-all}"
LOG_FILE="${BREEZE_LOG_FILE:-$DATA_DIR/logs/breeze-api.log}"

fail() { printf '[run] ERROR: %s\n' "$*" >&2; exit 1; }

# --------------------------------------------------------------- preflight --
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  fail "Python environment not found: $VENV_DIR — run deploy/wsl/install.sh first."
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
  fail "Model checkpoint not found: $MODEL_DIR — re-run deploy/wsl/install.sh without --skip-model."
fi
if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
  cat >&2 <<'EOF'
[run] ERROR: nvidia-smi is unavailable inside WSL — the GPU is not reachable.
This is usually the WSL dxg failure after a silent Windows driver upgrade.
Fix from Windows PowerShell: `wsl --shutdown`, wait ~8 s, reopen WSL, retry.
See docs/TROUBLESHOOTING.md ("WSL dxg 失效").
EOF
  exit 1
fi

# ---------------------------------------------------------- already running -
health_ok() {
  curl --fail --silent --max-time 5 "http://127.0.0.1:${PORT}/health" >/dev/null 2>&1
}
already_running() {
  pgrep -f 'breeze_infer.api' >/dev/null 2>&1
}
if already_running; then
  if health_ok; then
    printf '[run] API already healthy on port %s — nothing to do.\n' "$PORT"
    exit 0
  fi
  printf '[run] WARNING: an existing breeze_infer.api process is NOT healthy on port %s; stopping it.\n' "$PORT"
  pkill -f 'breeze_infer.api' 2>/dev/null || true
  sleep 2
fi
if health_ok; then
  printf '[run] port %s answers /health but no breeze_infer.api process was found; refusing to start a second listener.\n' "$PORT"
  exit 1
fi

# Do not let a Windows CUDA toolkit inherited through WSL interop shadow the
# Linux toolchain used by Triton/Inductor.
PATH="$(printf '%s' "$PATH" | tr ':' '\n' | grep -v '/mnt/c/Program Files/NVIDIA GPU Computing Toolkit/' | paste -sd: -)"
export PATH
export PYTHONUNBUFFERED=1
export PYTHONPATH="$REPO_DIR${PYTHONPATH:+:$PYTHONPATH}"
export BREEZE_IDLE_TIMEOUT="${BREEZE_IDLE_TIMEOUT:-120}"
export BREEZE_GEN_TIMEOUT="${BREEZE_GEN_TIMEOUT:-180}"
export BREEZE_GEN_STALL="${BREEZE_GEN_STALL:-45}"
export BREEZE_LOCK_TIMEOUT="${BREEZE_LOCK_TIMEOUT:-300}"
export TORCHINDUCTOR_CACHE_DIR="${TORCHINDUCTOR_CACHE_DIR:-$DATA_DIR/torchinductor}"
export TRITON_CACHE_DIR="${TRITON_CACHE_DIR:-$DATA_DIR/triton}"
mkdir -p "$(dirname "$LOG_FILE")" "$TORCHINDUCTOR_CACHE_DIR" "$TRITON_CACHE_DIR"

case "$FAST_MODE" in
  fast-all) FAST_ARGS=(--fast-all) ;;
  partial) FAST_ARGS=(--fast-text-encoder --fast-backbone-prefill --fast-backbone-decode --fast-codec --no-fast-depth-decoder) ;;
  eager) FAST_ARGS=(--no-fast-all) ;;
  *) fail "Unsupported BREEZE_FAST_MODE=$FAST_MODE (expected fast-all, partial, or eager)" ;;
esac

cd "$REPO_DIR"
printf '[launcher] starting mode=%s model=%s port=%s idle=%ss\n' \
  "$FAST_MODE" "$MODEL_DIR" "$PORT" "$BREEZE_IDLE_TIMEOUT" >> "$LOG_FILE"
exec "$VENV_DIR/bin/python" -m breeze_infer.api "$MODEL_DIR" \
  --host 0.0.0.0 --port "$PORT" "${FAST_ARGS[@]}" >> "$LOG_FILE" 2>&1
