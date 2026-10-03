#!/usr/bin/env bash
# Wartet, bis der Inferenz-Runtime antwortet. Ein Kaltstart laedt ~50 GB
# Gewichte und warmt CUDA-Graphen auf - das dauert gut und gerne 15 Minuten.
#
#   ./scripts/wait-for-runtime.sh                bis zu 20 Minuten
#   RUNTIME_WAIT_SECONDS=3600 ./scripts/wait-for-runtime.sh
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${RUNTIME_WAIT_SECONDS:=1200}"
: "${RUNTIME_POLL_SECONDS:=10}"
url="http://127.0.0.1:${PENNYROYAL_PORT}/health"
deadline=$(( $(date +%s) + RUNTIME_WAIT_SECONDS ))
printf 'Warte auf %s (max. %s Sekunden)\n' "${url}" "${RUNTIME_WAIT_SECONDS}"
while :; do
  if curl -fsS --max-time 8 "${url}" >/dev/null 2>&1; then
    printf 'Runtime ist bereit (%s)\n' "$(date -Is)"
    exit 0
  fi
  if (( $(date +%s) >= deadline )); then
    printf 'TIMEOUT: Runtime antwortet nicht innerhalb von %s Sekunden.\n' "${RUNTIME_WAIT_SECONDS}" >&2
    printf 'Waehrend des Wartens lief etwas schief? Pruefen:\n' >&2
    printf '  systemctl --user status pennyroyal.service --no-pager\n' >&2
    printf '  journalctl --user -u pennyroyal.service -n 120 --no-pager\n' >&2
    exit 1
  fi
  sleep "${RUNTIME_POLL_SECONDS}"
done
