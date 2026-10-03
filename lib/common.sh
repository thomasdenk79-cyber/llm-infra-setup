#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${REPO_ROOT}/state"
# shellcheck disable=SC2034  # wird von den aufrufenden Skripten benutzt
SECRETS_DIR="${LLM_INFRA_SECRETS_DIR:-${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra}"
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

# --- operator guidance -----------------------------------------------------
# Every user-facing script ends with the exact next command, so an operator
# never has to guess what a green or red line means.
is_true() { [[ "${1:-0}" == 1 || "${1:-}" == true || "${1:-}" == yes ]]; }
need_cmd() {
  local cmd="$1" hint="${2:-}"
  have "${cmd}" && return 0
  printf 'FEHLT: Das Programm "%s" ist nicht installiert.\n' "${cmd}" >&2
  [[ -n "${hint}" ]] && printf 'Jetzt ausführen: %s\n' "${hint}" >&2
  return 127
}
run() { log "+ $*"; "$@"; }

# --- secrets ---------------------------------------------------------------
random_secret() {
  local bytes="${1:-16}"
  if have openssl; then
    openssl rand -hex "${bytes}"
  else
    head -c "${bytes}" /dev/urandom | od -An -tx1 | tr -d ' \n'
  fi
}
write_secret_file() {
  # write_secret_file <path>  (content on stdin) with 0600 and no clobber.
  local path="$1"
  install -d -m 0700 "$(dirname -- "${path}")"
  if [[ -e "${path}" ]]; then
    log "keeping existing secret file: ${path}"
    return 0
  fi
  (umask 077; cat > "${path}")
  chmod 0600 "${path}"
}
