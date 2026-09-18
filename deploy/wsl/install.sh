#!/usr/bin/env bash
# Install Breeze TTS 2 into a WSL2 Ubuntu distro.
#
# Safe to re-run: every step is idempotent and missing prerequisites fail fast
# with an actionable message. Downloads fall back from the primary endpoint to
# the China mirror automatically when the network blocks the first choice.
set -Eeuo pipefail

SOURCE_REPO=""
REPO_DIR="/opt/breeze-tts-local-windows"
DATA_DIR="/opt/breeze-tts-data"
VENV_DIR="/opt/breeze-tts-venv"
MODEL_DIR="/opt/breeze-tts-data/models/Breeze-TTS-2"
FAST_MODE="fast-all"
TORCH_INDEX_URL="https://mirror.sjtu.edu.cn/pytorch-wheels/cu128"
TORCH_INDEX_URL_FALLBACK="https://download.pytorch.org/whl/cu128"
PYPI_INDEX_URL="https://pypi.org/simple"
PYPI_INDEX_URL_FALLBACK="https://mirrors.aliyun.com/pypi/simple"
HF_ENDPOINT="https://hf-mirror.com"
HF_ENDPOINT_FALLBACK="https://huggingface.co"
DRIVER_MIN_VERSION=550.0
SKIP_MODEL=0

log()  { printf '[install] %s\n' "$*"; }
fail() { printf '[install] ERROR: %s\n' "$*" >&2; exit 1; }

# Retry a command, alternating between the primary and the fallback index.
# Usage: pip_with_fallback <primary-url> <fallback-url> <pip args...>
pip_with_fallback() {
  local primary="$1" fallback="$2"; shift 2
  log "pip install (index: $primary)"
  if "$PYTHON" -m pip install --timeout 30 --retries 2 --index-url "$primary" "$@"; then
    return 0
  fi
  if [[ "$primary" == "$fallback" ]]; then
    fail "pip install failed against $primary and no fallback is configured."
  fi
  log "pip failed against $primary, retrying with fallback $fallback"
  "$PYTHON" -m pip install --timeout 30 --retries 2 --index-url "$fallback" "$@"
}

while (($#)); do
  case "$1" in
    --source-repo) SOURCE_REPO="$2"; shift 2 ;;
    --repo-dir) REPO_DIR="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --venv) VENV_DIR="$2"; shift 2 ;;
    --model-dir) MODEL_DIR="$2"; shift 2 ;;
    --fast-mode) FAST_MODE="$2"; shift 2 ;;
    --torch-index-url) TORCH_INDEX_URL="$2"; shift 2 ;;
    --pypi-index-url) PYPI_INDEX_URL="$2"; shift 2 ;;
    --hf-endpoint) HF_ENDPOINT="$2"; shift 2 ;;
    --skip-model) SKIP_MODEL=1; shift ;;
    *) echo "Unknown option: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$SOURCE_REPO" ]]; then SOURCE_REPO="$REPO_DIR"; fi
if [[ "$FAST_MODE" != "fast-all" && "$FAST_MODE" != "eager" && "$FAST_MODE" != "partial" ]]; then
  echo "--fast-mode must be fast-all, partial, or eager" >&2
  exit 2
fi

if (( EUID != 0 )); then
  sudo_args=(
    --source-repo "$SOURCE_REPO" --repo-dir "$REPO_DIR" --data-dir "$DATA_DIR"
    --venv "$VENV_DIR" --model-dir "$MODEL_DIR" --fast-mode "$FAST_MODE"
    --torch-index-url "$TORCH_INDEX_URL" --pypi-index-url "$PYPI_INDEX_URL"
    --hf-endpoint "$HF_ENDPOINT"
  )
  if (( SKIP_MODEL == 1 )); then sudo_args+=(--skip-model); fi
  exec sudo -E bash "$0" "${sudo_args[@]}"
fi

# --------------------------------------------------------------- preflight --
log "STEP 1/7 preflight checks"

if [[ ! -d "$SOURCE_REPO" ]]; then
  fail "source repository not found: $SOURCE_REPO"
fi
if [[ ! -f "$SOURCE_REPO/requirements.txt" ]]; then
  fail "not a breeze-tts-local-windows checkout (requirements.txt missing): $SOURCE_REPO"
fi

# free disk space; the checkpoint alone is ~7.7 GB, venv + caches add several more
avail_kb=$(df -Pk "$(dirname "$DATA_DIR")" | awk 'NR==2 {print $4}')
if [[ -z "$avail_kb" ]] || (( avail_kb < 20 * 1024 * 1024 )); then
  fail "less than 20 GB free under $(dirname "$DATA_DIR") (model ~7.7 GB + venv + caches). Free space and re-run."
fi
log "disk OK ($(($(avail_kb) / 1024 / 1024)) GB free under $(dirname "$DATA_DIR"))"

# /dev/dxg is the WSL2 GPU paravirtualization device. It disappears after some
# host driver upgrades (known incident: silent upgrade to 616.64) until the WSL
# VM is restarted from the Windows side (wsl --shutdown then reconnect).
if [[ ! -e /dev/dxg ]]; then
  cat >&2 <<'EOF'
ERROR: /dev/dxg is missing, so this WSL distro cannot see the NVIDIA GPU.
Fix from Windows PowerShell:
  wsl --shutdown
  # wait ~8 seconds, then reopen the WSL session and re-run this script.
If /dev/dxg is still missing, update the NVIDIA Windows driver and reboot.
EOF
  exit 1
fi
log "/dev/dxg present"

if ! command -v nvidia-smi >/dev/null 2>&1; then
  fail "nvidia-smi not found inside WSL. Install/reinstall the NVIDIA Windows driver (it ships the WSL CUDA driver) and restart WSL."
fi
if ! nvidia-smi >/dev/null 2>&1; then
  cat >&2 <<'EOF'
ERROR: nvidia-smi exists but failed inside WSL. This is the classic WSL dxg
failure (often right after a silent Windows GPU driver upgrade, e.g. 616.64).
Fix: in Windows PowerShell run `wsl --shutdown`, wait ~8 s, reopen WSL, re-run.
If it still fails, reboot Windows or reinstall the NVIDIA driver.
EOF
  exit 1
fi
GPU_NAME=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1 || true)
GPU_MEM_MB=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>/dev/null | head -1 | tr -dc '0-9' || true)
GPU_DRIVER=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1 || true)
log "GPU: ${GPU_NAME:-unknown}, ${GPU_MEM_MB:-?} MiB, driver ${GPU_DRIVER:-unknown}"
if [[ -n "$GPU_DRIVER" ]]; then
  DRIVER_MAJOR="${GPU_DRIVER%%.*}"
  DRIVER_MIN_MAJOR="${DRIVER_MIN_VERSION%%.*}"
  if [[ "$DRIVER_MAJOR" =~ ^[0-9]+$ ]] && (( DRIVER_MAJOR < DRIVER_MIN_MAJOR )); then
    log "WARNING: NVIDIA driver $GPU_DRIVER is older than $DRIVER_MIN_VERSION; CUDA 12.8 wheels in WSL2 may fail. Consider updating the Windows driver."
  fi
fi
if [[ -n "$GPU_MEM_MB" ]] && (( GPU_MEM_MB < 20000 )); then
  fail "GPU has only ${GPU_MEM_MB} MiB. fast-all mode needs ~21.5 GiB free VRAM; use --fast-mode eager on smaller cards."
fi

# --------------------------------------------------------------- packages ---
log "STEP 2/7 apt packages"
export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git gcc g++ make python3 python3-pip python3-venv libsndfile1

# ------------------------------------------------------------- repo layout --
log "STEP 3/7 repository copy"
install -d "$REPO_DIR" "$DATA_DIR" "$(dirname "$MODEL_DIR")"
if [[ "$SOURCE_REPO" != "$REPO_DIR" ]]; then
  # The source is normally the Windows checkout mounted under /mnt/c. Keep a
  # Linux copy for faster imports and predictable scheduled-task paths.
  cp -a "$SOURCE_REPO/." "$REPO_DIR/"
fi

# ----------------------------------------------------------------- venv -----
log "STEP 4/7 python environment"
if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"

# curl check BEFORE pip so a dead network fails fast with a clear message.
probe_url() {
  curl --fail --silent --head --max-time 10 -o /dev/null "$1" || return 1
}
if ! probe_url "$PYPI_INDEX_URL"; then
  log "PyPI index $PYPI_INDEX_URL unreachable, switching to fallback $PYPI_INDEX_URL_FALLBACK"
  PYPI_INDEX_URL="$PYPI_INDEX_URL_FALLBACK"
fi

"$PYTHON" -m pip install --upgrade pip --index-url "$PYPI_INDEX_URL"
pip_with_fallback "$TORCH_INDEX_URL" "$TORCH_INDEX_URL_FALLBACK" torch==2.9.1 torchaudio==2.9.1
pip_with_fallback "$PYPI_INDEX_URL" "$PYPI_INDEX_URL_FALLBACK" -r "$REPO_DIR/requirements.txt"
if [[ "$FAST_MODE" == "fast-all" || "$FAST_MODE" == "partial" ]]; then
  pip_with_fallback "$PYPI_INDEX_URL" "$PYPI_INDEX_URL_FALLBACK" triton==3.4.0
fi

# ----------------------------------------------------------------- model ----
log "STEP 5/7 model checkpoint"
download_model() {
  local endpoint="$1"
  HF_ENDPOINT="$endpoint" "$PYTHON" "$REPO_DIR/scripts/download_model.py" \
    --dest "$MODEL_DIR" --endpoint "$endpoint"
}
if (( SKIP_MODEL == 0 )); then
  # snapshot_download resumes partial downloads, so re-running after a network
  # failure continues instead of restarting from zero.
  if ! download_model "$HF_ENDPOINT"; then
    if [[ "$HF_ENDPOINT" != "$HF_ENDPOINT_FALLBACK" ]]; then
      log "download via $HF_ENDPOINT failed, retrying via $HF_ENDPOINT_FALLBACK"
      download_model "$HF_ENDPOINT_FALLBACK"
    else
      fail "model download failed via $HF_ENDPOINT. Check the network or set --hf-endpoint manually."
    fi
  fi
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
  echo "Model checkpoint is missing: $MODEL_DIR/config.json" >&2
  echo "Re-run without --skip-model or place a complete Breeze checkpoint there." >&2
  exit 1
fi
"$PYTHON" "$REPO_DIR/scripts/patch_model_config.py" "$MODEL_DIR"

# ------------------------------------------------------------------- env ----
log "STEP 6/7 write breeze.env"
install -d "$DATA_DIR/logs"
umask 077
printf '%s\n' \
  "BREEZE_REPO_DIR=$REPO_DIR" \
  "BREEZE_DATA_DIR=$DATA_DIR" \
  "BREEZE_VENV=$VENV_DIR" \
  "BREEZE_MODEL_DIR=$MODEL_DIR" \
  "BREEZE_FAST_MODE=$FAST_MODE" \
  "BREEZE_PORT=7860" \
  "BREEZE_IDLE_TIMEOUT=120" \
  "BREEZE_GEN_TIMEOUT=180" \
  "BREEZE_GEN_STALL=45" \
  "BREEZE_LOCK_TIMEOUT=300" \
  "HF_ENDPOINT=$HF_ENDPOINT" \
  "TORCHINDUCTOR_CACHE_DIR=$DATA_DIR/torchinductor" \
  "TRITON_CACHE_DIR=$DATA_DIR/triton" \
  > "$DATA_DIR/breeze.env"

log "STEP 7/7 done"
printf 'WSL_INSTALL_OK\nREPO_DIR=%s\nMODEL_DIR=%s\nFAST_MODE=%s\n' \
  "$REPO_DIR" "$MODEL_DIR" "$FAST_MODE"
