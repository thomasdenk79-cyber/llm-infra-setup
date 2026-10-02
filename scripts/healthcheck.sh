#!/usr/bin/env bash
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; port="${PENNYROYAL_PORT:-8001}"; bad=0
ok(){ printf '\033[32m[OK]\033[0m %s\n' "$*"; }; warn(){ printf '\033[33m[WARN]\033[0m %s\n' "$*"; }; fail(){ printf '\033[31m[FAIL]\033[0m %s\n' "$*"; bad=1; }
command -v curl >/dev/null || fail 'curl missing'; command -v podman >/dev/null && ok 'podman available' || warn 'podman unavailable'
if command -v zpool >/dev/null; then zpool list >/dev/null 2>&1 && ok 'ZFS healthy' || warn 'ZFS unavailable/unhealthy'; else warn 'ZFS tools unavailable'; fi
df -P "$root" | awk 'NR==2 {if ($5+0 < 90) exit 0; exit 1}' && ok 'Disk usage below 90%' || warn 'Disk usage >= 90%'
command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && ok 'NVIDIA reachable' || warn 'NVIDIA unavailable'
if curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:${port}/health" >/dev/null; then ok "Pennyroyal API healthy (:${port})"; else fail "Pennyroyal API unavailable (:${port})"; fi
if [[ "${LITELLM_PORT:-4000}" != disabled ]] && curl --fail --silent --max-time 3 "http://127.0.0.1:${LITELLM_PORT:-4000}/health" >/dev/null 2>&1; then ok 'LiteLLM API healthy'; else warn 'LiteLLM unavailable'; fi
if ((bad==0)); then echo 'SYSTEM HEALTHY'; else echo 'SYSTEM UNHEALTHY'; fi; exit "$bad"
