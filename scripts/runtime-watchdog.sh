#!/usr/bin/env bash
# Wacht über den Pennyroyal-Runtime. Standardmaessig warnt es nur, weil ein
# Neustart ~15 Minuten dauert und laufende Anfragen abbricht. Automatischen
# Neustart nur einschalten, wenn das bewusst gewollt ist:
#   PENNY_WATCHDOG_RESTART=1 ./scripts/runtime-watchdog.sh --install
#
# Die Unit wird nicht geraten: zuerst gilt RUNTIME_UNIT aus config/host.env, sonst
# wird die Unit gesucht, deren ContainerName zu RUNTIME_CONTAINER passt. Ohne
# Treffer bleibt der Waechter bei der Warnung und startet nichts.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${RUNTIME_PORT:=${PENNYROYAL_PORT:-8001}}"   # hier: 30000 (vLLM)
: "${VLLM_METRICS_PORT:=30001}"                 # Weiterleiter, bringt vLLM-Metriken ins Netz
: "${PENNY_WATCHDOG_RESTART:=0}"
: "${PENNY_WATCHDOG_FAILURES:=3}"
state_file="${STATE_DIR}/watchdog.state"
log_file="${STATE_DIR}/watchdog.log"
mkdir -p "${STATE_DIR}"

say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${log_file}"; }

check_health() { curl -fsS --max-time 10 "http://127.0.0.1:${RUNTIME_PORT}/health" >/dev/null 2>&1; }

laufzeit_unit_bestimmen() {
  # Wie in apply-runtime-unit.sh: erst die Ansage, sonst die Unit zum Container.
  [[ -n "${RUNTIME_UNIT:-}" ]] && { printf '%s' "${RUNTIME_UNIT}"; return 0; }
  local datei
  for datei in "${root}"/quadlet/*.container; do
    [[ -f "${datei}" ]] || continue
    if grep -qs "^ContainerName=${RUNTIME_CONTAINER:-__keiner__}\$" "${datei}"; then
      printf '%s' "$(basename "${datei}" .container)"
      return 0
    fi
  done
  return 1
}

running_requests() {
  # Erst der Weiterleiter (vLLM-Metriken), dann die Runtime selbst; das
  # sglang-Muster bleibt fuer Rechner mit Pennyroyal stehen. Ohne Zahl kommt
  # 'unbekannt' - der Aufrufer verschiebt dann, statt zu raten.
  local orte port mess wert
  orte=("${VLLM_METRICS_PORT:-30001}" "${RUNTIME_PORT:-8001}" "${PENNYROYAL_PORT:-8001}")
  for port in "${orte[@]}"; do
    mess="$(curl -fsS --max-time 5 "http://127.0.0.1:${port}/metrics" 2>/dev/null)" || continue
    wert="$(printf '%s\n' "${mess}" \
      | awk '/^vllm:num_requests_running\{/ {print $2; gefunden=1; exit}
              /^sglang:num_running_reqs\{/ {print $2; gefunden=1; exit}
              END { if (!gefunden) print "unbekannt" }')"
    [[ "${wert}" == 'unbekannt' || -z "${wert}" ]] && continue
    printf '%s' "${wert}"
    return 0
  done
  printf 'unbekannt'
}

case "${1:-check}" in
  --install|install)
    install_systemd_units "${HOME}/.config/systemd/user" llm-runtime-watchdog.service llm-runtime-watchdog.timer
    systemctl --user daemon-reload
    systemctl --user enable --now llm-runtime-watchdog.timer
    say 'Watchdog-Timer aktiv. Automatischer Neustart:'"$([ "${PENNY_WATCHDOG_RESTART}" == 1 ] && echo AN || echo AUS)"
    printf 'Automatisch neu starten nur mit: PENNY_WATCHDOG_RESTART=1 ./scripts/runtime-watchdog.sh --install\n'
    ;;
  --uninstall|uninstall)
    systemctl --user disable --now llm-runtime-watchdog.timer 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/llm-runtime-watchdog.service" "${HOME}/.config/systemd/user/llm-runtime-watchdog.timer"
    systemctl --user daemon-reload
    say 'Watchdog entfernt.'
    ;;
  check)
    fails="$(cat "${state_file}" 2>/dev/null || echo 0)"
    if check_health; then
      [[ "${fails}" != 0 ]] && say 'Runtime ist wieder erreichbar; Zaehler zurueckgesetzt.'
      echo 0 > "${state_file}"
      say 'OK runtime healthy'
      exit 0
    fi
    fails=$((fails + 1)); echo "${fails}" > "${state_file}"
    say "FEHLER: /health beantwortet nicht (Versuch ${fails}/${PENNY_WATCHDOG_FAILURES})."
    laufzeit_unit="$(laufzeit_unit_bestimmen || true)"
    say "  Erste Hilfe: journalctl --user -u ${laufzeit_unit:-LAUFZEIT_UNIT}.service -n 120 --no-pager"
    say '  Naechster Schritt: ./scripts/doctor.sh'
    if (( fails < PENNY_WATCHDOG_FAILURES )); then exit 0; fi
    if [[ "${PENNY_WATCHDOG_RESTART}" != 1 ]]; then
      say 'Auto-Neustart ist AUS (PENNY_WATCHDOG_RESTART=0). Manuell prüfen und dann:'
      say '  ./scripts/apply-runtime-unit.sh --restart-only'
      exit 1
    fi
    running="$(running_requests)"
    if [[ "${running}" == 'unbekannt' || "${running%.*}" != "0" ]]; then
      say 'Auto-Neustart verschoben: laufende Anfragen ('"${running}"') oder keine Zahl erreichbar.'
      exit 0
    fi
    laufzeit_unit="$(laufzeit_unit_bestimmen || true)"
    if [[ -z "${laufzeit_unit}" ]]; then
      say 'Keine Unit zur Laufzeit gefunden - kein Auto-Neustart. RUNTIME_UNIT in config/host.env setzen.'
      exit 1
    fi
    say 'Auto-Neustart ausgelöst (Runtime war krank und leer).'
    systemctl --user restart "${laufzeit_unit}.service" || say 'Neustart fehlgeschlagen; Journal prüfen.'
    echo 0 > "${state_file}"
    ;;
  *)
    printf 'usage: %s [check|--install|--uninstall]\n' "$0" >&2
    exit 2
    ;;
esac
