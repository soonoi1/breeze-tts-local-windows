#!/usr/bin/env bash
# Health check for the WSL-local API.
set -Eeuo pipefail
PORT="${BREEZE_PORT:-7860}"
exec curl --fail --silent --show-error --max-time 10 "http://127.0.0.1:${PORT}/health"
