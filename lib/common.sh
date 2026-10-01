#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/state"
mkdir -p "${STATE_DIR}"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }
capture() {
  local title="$1"; shift
  printf '\n===== %s =====\n' "$title"
  if "$@" 2>&1; then return 0; fi
  printf '[unavailable or failed: %s]\n' "$*"
  return 0
}

