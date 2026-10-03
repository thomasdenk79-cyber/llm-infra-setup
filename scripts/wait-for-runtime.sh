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
# Ein Kaltstart mit NVMe-PLE und CUDA-Profiling dauert normalerweise etwa
# 20 Minuten. Nach 30 Minuten warnen wir. Nach 40 Minuten brechen wir nur ab,
# wenn auch seit zehn Minuten weder Journal- noch CPU-/GPU-Fortschritt erkennbar ist.
: "${RUNTIME_WAIT_SECONDS:=2400}"
: "${RUNTIME_POLL_SECONDS:=10}"
: "${RUNTIME_STALL_SECONDS:=600}"
: "${RUNTIME_STATUS_INTERVAL:=60}"
url="http://127.0.0.1:${PENNYROYAL_PORT}/health"
started_at="$(date +%s)"
warn_at=$(( started_at + 1800 ))
deadline=$(( started_at + RUNTIME_WAIT_SECONDS ))
warned=0
last_status=0
printf 'Warte auf %s (max. %s Sekunden)\n' "${url}" "${RUNTIME_WAIT_SECONDS}"
while :; do
  if curl -fsS --max-time 8 "${url}" >/dev/null 2>&1; then
    printf 'Runtime ist bereit (%s)\n' "$(date -Is)"
    exit 0
  fi
  now="$(date +%s)"
  if (( warned == 0 && now >= warn_at )); then
    printf 'WARNUNG: Runtime braucht bereits 30 Minuten; pruefe ab jetzt Log- und Prozessfortschritt.\n' >&2
    warned=1
  fi
  if (( now - last_status >= RUNTIME_STATUS_INTERVAL )); then
    last_status="${now}"
    container_running="$(podman inspect --format '{{.State.Running}}' pennyroyal 2>/dev/null || true)"
    if [[ "${container_running}" != true ]]; then
      printf 'FEHLER: Pennyroyal-Container laeuft nicht mehr. Letzte Diagnose:\n' >&2
      journalctl --user -u pennyroyal.service -n 40 --no-pager >&2 || true
      exit 1
    fi

    last_log="$(journalctl --user -u pennyroyal.service --since "@${started_at}" -n 1 --output=short-unix --no-pager 2>/dev/null | awk 'END {print $1}')"
    log_age="unknown"
    if [[ "${last_log}" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
      log_age="$(( now - ${last_log%.*} ))"
    fi
    cpu="$(podman stats --no-stream --format '{{.CPU}}' pennyroyal 2>/dev/null | tr -d '% ' || true)"
    gpu="$(nvidia-smi --query-gpu=utilization.gpu --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo 0)"
    vram="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>/dev/null | awk '{s+=$1} END {print s+0}' || echo 0)"
    printf 'STARTUP_STATUS elapsed=%ss log_age=%ss container=%s cpu=%s%% gpu=%s%% vram=%sMiB\n' \
      "$(( now - started_at ))" "${log_age}" "${container_running}" "${cpu:-unknown}" "${gpu:-0}" "${vram:-0}"

    if (( now >= deadline )); then
      cpu_active=0; gpu_active=0; recent_logs=0
      awk -v x="${cpu:-0}" 'BEGIN {exit !(x+0 > 0.1)}' && cpu_active=1
      (( ${gpu:-0} > 0 )) && gpu_active=1
      [[ "${log_age}" =~ ^[0-9]+$ ]] && (( log_age < RUNTIME_STALL_SECONDS )) && recent_logs=1
      if (( cpu_active == 0 && gpu_active == 0 && recent_logs == 0 )); then
        printf 'TIMEOUT: Nach %s Sekunden kein Logfortschritt seit %s Sekunden und CPU/GPU inaktiv.\n' \
          "${RUNTIME_WAIT_SECONDS}" "${RUNTIME_STALL_SECONDS}" >&2
        printf 'Letzte Diagnose:\n' >&2
        journalctl --user -u pennyroyal.service -n 120 --no-pager >&2 || true
        exit 1
      fi
      printf 'WARNUNG: Zeitgrenze erreicht, aber Aktivitaet erkennbar; warte weiter und pruefe erneut.\n' >&2
      deadline=$(( now + 300 ))
    fi
  fi
  sleep "${RUNTIME_POLL_SECONDS}"
done
