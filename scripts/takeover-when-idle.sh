#!/usr/bin/env bash
# Wartet auf Leerlauf der Inferenz-Laufzeit und uebergibt sie dann an ihre Unit.
#
#   ./scripts/takeover-when-idle.sh check          eine Runde (das ruft der Timer)
#   ./scripts/takeover-when-idle.sh --install      Timer alle 10 Minuten
#   ./scripts/takeover-when-idle.sh --uninstall
#   ./scripts/takeover-when-idle.sh --status
#   LLM_TAKEOVER_AUTOMATIK=1 ./scripts/takeover-when-idle.sh --install
#
# Warum gewartet wird: die Regel des Repos lautet "Neustart der Inferenz-Runtime nur,
# wenn keine laufenden Anfragen laufen, und als eigener angekuendigter Schritt".
# Anfragen zaehlt der Weiterleiter (vllm:num_requests_running); dieser Waechter wartet,
# bis sie dreimal hintereinander null sind.
#
# Was er dann tut, entscheidet die Installation: standardmaessig legt er nur
# state/runtime-takeover/bereit.txt ab und nennt den Befehl - kein Grund, eine
# Grafikkarte ungefragt neu anzulaufen. Mit LLM_TAKEOVER_AUTOMATIK=1 ruft er
# apply-runtime-unit.sh --takeover, und das prueft die Anfragezahl erneut und bricht
# bei unbekanntem Wert ab (zwei Riegel, einer vom Waechter, einer vom Werkzeug).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
# shellcheck disable=SC1090
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${RUNTIME_CONTAINER:=flash-next-v3}"
: "${VLLM_METRICS_PORT:=30001}"
: "${RUNTIME_PORT:=30000}"
: "${LLM_TAKEOVER_PROBEN:=3}"
: "${LLM_TAKEOVER_AUTOMATIK:=0}"

state_dir="${STATE_DIR}/runtime-takeover"
zaehler_datei="${state_dir}/leerlauf"
bereit_datei="${state_dir}/bereits.txt"
log_datei="${state_dir}/takeover.log"
mkdir -p "${state_dir}"
chmod 0700 "${state_dir}"

say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${log_datei}"; }

 laufend_anfragen() {
  local orte port mess wert
  orte=("${VLLM_METRICS_PORT}" "${RUNTIME_PORT}")
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

laufzeit_unit() {
  [[ -n "${RUNTIME_UNIT:-}" ]] && { printf '%s' "${RUNTIME_UNIT}"; return 0; }
  local datei
  for datei in "${root}"/quadlet/*.container; do
    [[ -f "${datei}" ]] || continue
    if grep -qs "^ContainerName=${RUNTIME_CONTAINER}\$" "${datei}"; then
      printf '%s' "$(basename "${datei}" .container)"
      return 0
    fi
  done
  return 1
}

einheiten_entfernen() {
  systemctl --user disable --now llm-runtime-takeover.timer >/dev/null 2>&1 || true
}

check() {
  local unit running zaehler
  unit="$(laufzeit_unit || true)"
  if [[ -z "${unit}" ]]; then
    say "Keine Unit zur Laufzeit ${RUNTIME_CONTAINER} gefunden - nichts zu uebernehmen."
    printf '  Naechster Befehl: ./scripts/76-setup-runtime-unit.sh --import-from-container %s\n' "${RUNTIME_CONTAINER}"
    return 1
  fi
  if systemctl --user is-active --quiet "${unit}.service" 2>/dev/null \
     && podman ps --format '{{.Names}}' | grep -qx "${RUNTIME_CONTAINER}"; then
    say "Uebernommen: ${unit}.service besitzt ${RUNTIME_CONTAINER}; Timer wird abgewahlt."
    rm -f "${bereit_datei}" "${zaehler_datei}"
    einheiten_entfernen
    return 0
  fi

  running="$(laufend_anfragen)"
  zaehler="$(cat "${zaehler_datei}" 2>/dev/null || echo 0)"
  if [[ "${running%.*}" == '0' ]]; then
    zaehler=$((zaehler + 1))
    echo "${zaehler}" > "${zaehler_datei}"
    anzeige=${zaehler}
    (( anzeige > LLM_TAKEOVER_PROBEN )) && anzeige=${LLM_TAKEOVER_PROBEN}
    say "Leerlauf gemessen (${anzeige}/${LLM_TAKEOVER_PROBEN})."
    if (( zaehler < LLM_TAKEOVER_PROBEN )); then
      return 0
    fi
  else
    if [[ "${zaehler}" != "0" ]]; then
      say "Anfragen laufen (${running}) - Zaehler zurueckgesetzt."
    fi
    echo 0 > "${zaehler_datei}"
    return 0
  fi

  if [[ "${LLM_TAKEOVER_AUTOMATIK}" == '1' ]]; then
    say "Automatik ist an: Uebernahme durch ${unit}.service wird ausgeloest."
    if "${root}/scripts/apply-runtime-unit.sh" --takeover >>"${log_datei}" 2>&1; then
      say "Uebernahme erfolgreich; Timer waehlt sich ab."
      rm -f "${bereit_datei}" "${zaehler_datei}"
      einheiten_entfernen
      return 0
    fi
    say "Uebernahme fehlgeschlagen - Zaehler laeuft neu, Grund steht in diesem Protokoll."
    echo 0 > "${zaehler_datei}"
    return 1
  fi

  if [[ ! -f "${bereit_datei}" ]]; then
    printf '%s\n' "Leerlauf erreicht: ${RUNTIME_CONTAINER} kann an ${unit}.service uebergeben werden." > "${bereit_datei}"
    say "Bereit gemeldet: ${bereit_datei}"
  fi
  say "Keine Automatik (LLM_TAKEOVER_AUTOMATIK=0). Ausfuehren: ./scripts/apply-runtime-unit.sh --takeover"
  return 0
}

case "${1:-check}" in
  --install|install)
    install_systemd_units "${HOME}/.config/systemd/user" llm-runtime-takeover.service llm-runtime-takeover.timer
    systemd_reload
    systemctl --user enable --now llm-runtime-takeover.timer
    say "Wartender Uebernahme-Timer aktiv (alle 10 Minuten). Automatik: ${LLM_TAKEOVER_AUTOMATIK} (1 = er wuerde selbst neu starten)."
    printf 'Naechster Schritt: ./scripts/takeover-when-idle.sh --status\n'
    ;;
  --uninstall|uninstall)
    einheiten_entfernen
    rm -f "${HOME}/.config/systemd/user/llm-runtime-takeover.service" "${HOME}/.config/systemd/user/llm-runtime-takeover.timer"
    systemd_reload
    say "Wartender Uebernahme-Timer entfernt."
    ;;
  --status|status)
    printf 'Protokoll (%s):\n' "${log_datei}"
    tail -6 "${log_datei}" 2>/dev/null || printf '  (noch nichts protokolliert)\n'
    printf 'Leerlauf-Zaehler: %s von %s\n' "$(cat "${zaehler_datei}" 2>/dev/null || echo 0)" "${LLM_TAKEOVER_PROBEN}"
    printf 'Timer: %s\n' "$(systemctl --user is-active llm-runtime-takeover.timer 2>/dev/null || echo inaktiv)"
    if [[ -f "${bereit_datei}" ]]; then
      printf 'Bereit: %s\n' "$(cat "${bereit_datei}")"
      printf '  Ausfuehren: ./scripts/apply-runtime-unit.sh --takeover\n'
    fi
    ;;
  check)
    check
    ;;
  *)
    printf 'usage: %s [check|--install|--uninstall|--status]\n' "$0" >&2
    exit 2
    ;;
esac
