#!/usr/bin/env bash
# Install Breeze TTS 2 into a WSL2 Ubuntu distro.
set -Eeuo pipefail

SOURCE_REPO=""
REPO_DIR="/opt/breeze-tts-local-windows"
DATA_DIR="/opt/breeze-tts-data"
VENV_DIR="/opt/breeze-tts-venv"
MODEL_DIR="/opt/breeze-tts-data/models/Breeze-TTS-2"
FAST_MODE="fast-all"
TORCH_INDEX_URL="https://mirror.sjtu.edu.cn/pytorch-wheels/cu128"
PYPI_INDEX_URL="https://pypi.org/simple"
HF_ENDPOINT="https://hf-mirror.com"
SKIP_MODEL=0

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
  exec sudo -E bash "$0" \
    --source-repo "$SOURCE_REPO" --repo-dir "$REPO_DIR" --data-dir "$DATA_DIR" \
    --venv "$VENV_DIR" --model-dir "$MODEL_DIR" --fast-mode "$FAST_MODE" \
    --torch-index-url "$TORCH_INDEX_URL" --pypi-index-url "$PYPI_INDEX_URL" \
    --hf-endpoint "$HF_ENDPOINT" $([[ $SKIP_MODEL == 1 ]] && printf '%s' --skip-model)
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git gcc g++ make python3 python3-pip python3-venv libsndfile1

install -d "$REPO_DIR" "$DATA_DIR" "$(dirname "$MODEL_DIR")"
if [[ "$SOURCE_REPO" != "$REPO_DIR" ]]; then
  # The source is normally the Windows checkout mounted under /mnt/c. Keep a
  # Linux copy for faster imports and predictable scheduled-task paths.
  cp -a "$SOURCE_REPO/." "$REPO_DIR/"
fi

if [[ ! -x "$VENV_DIR/bin/python" ]]; then
  python3 -m venv "$VENV_DIR"
fi
PYTHON="$VENV_DIR/bin/python"

"$PYTHON" -m pip install --upgrade pip --index-url "$PYPI_INDEX_URL"
"$PYTHON" -m pip install --upgrade --index-url "$TORCH_INDEX_URL" \
  torch==2.9.1 torchaudio==2.9.1
"$PYTHON" -m pip install --upgrade --index-url "$PYPI_INDEX_URL" \
  -r "$REPO_DIR/requirements.txt"
if [[ "$FAST_MODE" == "fast-all" || "$FAST_MODE" == "partial" ]]; then
  "$PYTHON" -m pip install --upgrade --index-url "$PYPI_INDEX_URL" triton==3.4.0
fi

if (( SKIP_MODEL == 0 )); then
  HF_ENDPOINT="$HF_ENDPOINT" "$PYTHON" "$REPO_DIR/scripts/download_model.py" \
    --dest "$MODEL_DIR" --endpoint "$HF_ENDPOINT"
fi
if [[ ! -f "$MODEL_DIR/config.json" ]]; then
  echo "Model checkpoint is missing: $MODEL_DIR/config.json" >&2
  echo "Re-run without --skip-model or place a complete Breeze checkpoint there." >&2
  exit 1
fi
"$PYTHON" "$REPO_DIR/scripts/patch_model_config.py" "$MODEL_DIR"

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

printf 'WSL_INSTALL_OK\nREPO_DIR=%s\nMODEL_DIR=%s\nFAST_MODE=%s\n' \
  "$REPO_DIR" "$MODEL_DIR" "$FAST_MODE"
