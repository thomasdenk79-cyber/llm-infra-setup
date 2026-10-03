#!/usr/bin/env bash
# Wacht über den Pennyroyal-Runtime. Standardmaessig warnt es nur, weil ein
# Neustart ~15 Minuten dauert und laufende Anfragen abbricht. Automatischen
# Neustart nur einschalten, wenn das bewusst gewollt ist:
#   PENNY_WATCHDOG_RESTART=1 ./scripts/runtime-watchdog.sh --install
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${PENNY_WATCHDOG_RESTART:=0}"
: "${PENNY_WATCHDOG_FAILURES:=3}"
state_file="${STATE_DIR}/watchdog.state"
log_file="${STATE_DIR}/watchdog.log"
mkdir -p "${STATE_DIR}"

say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${log_file}"; }

check_health() { curl -fsS --max-time 10 "http://127.0.0.1:${PENNYROYAL_PORT}/health" >/dev/null 2>&1; }

running_requests() {
  curl -fsS --max-time 5 "http://127.0.0.1:${PENNYROYAL_PORT}/metrics" 2>/dev/null \
    | awk '/^sglang:num_running_reqs\{/ {print $2; found=1} END{if(!found) print "unknown"}'
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
    say '  Erste Hilfe: journalctl --user -u pennyroyal.service -n 120 --no-pager'
    say '  Naechster Schritt: ./scripts/doctor.sh'
    if (( fails < PENNY_WATCHDOG_FAILURES )); then exit 0; fi
    if [[ "${PENNY_WATCHDOG_RESTART}" != 1 ]]; then
      say 'Auto-Neustart ist AUS (PENNY_WATCHDOG_RESTART=0). Manuell prüfen und dann:'
      say '  ./scripts/apply-runtime-unit.sh --restart-only'
      exit 1
    fi
    running="$(running_requests)"
    if [[ "${running}" != "0" && "${running}" != "unknown" ]]; then
      say 'Auto-Neustart verschoben: es laufen gerade Anfragen (running='"${running}"').'
      exit 0
    fi
    say 'Auto-Neustart ausgelöst (Runtime war krank und leer).'
    systemctl --user restart pennyroyal.service || say 'Neustart fehlgeschlagen; Journal prüfen.'
    echo 0 > "${state_file}"
    ;;
  *)
    printf 'usage: %s [check|--install|--uninstall]\n' "$0" >&2
    exit 2
    ;;
esac
