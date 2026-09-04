#!/usr/bin/env bash
# Stop only the Breeze API process in this WSL distro.
set -Eeuo pipefail
pkill -f 'breeze_infer.api' 2>/dev/null || true
sleep 2
if pgrep -af 'breeze_infer.api' >/dev/null 2>&1; then
  echo 'BREEZE_STILL_RUNNING'
  exit 1
fi
echo 'BREEZE_STOPPED'
