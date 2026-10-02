#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/state"
mkdir -p "${STATE_DIR}"

log() { printf '[%s] %s\n' "$(date -Is)" "$*"; }
retry() {
  local attempts="${RETRY_ATTEMPTS:-8}" delay="${RETRY_DELAY:-10}" n=1 rc=0
  while :; do
    "$@" && return 0
    rc=$?
    if ((n >= attempts)); then return "$rc"; fi
    log "Command failed (attempt ${n}/${attempts}); retrying in ${delay}s: $*"
    sleep "${delay}"
    n=$((n + 1)); if ((delay < 300)); then delay=$((delay * 2)); fi
  done
}
have() { command -v "$1" >/dev/null 2>&1; }
capture() {
  local title="$1"; shift
  printf '\n===== %s =====\n' "$title"
  if "$@" 2>&1; then return 0; fi
  printf '[unavailable or failed: %s]\n' "$*"
  return 0
}
