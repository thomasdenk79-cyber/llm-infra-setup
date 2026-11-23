#!/usr/bin/env bash
# Wacht ueber den LiteLLM-Gateway (nicht ueber die GPU-Runtime dafuer ist
# scripts/runtime-watchdog.sh da). Prueft die keyless Lebensanzeige und einen
# 1-Token-Ruf durch die Primaerstecke, und startet bei Ausfall ausschliesslich
# litellm.service neu - niemals pennyroyal oder etwas anderes.
#
#   ./scripts/litellm-watchdog.sh check       ein Durchlauf (Timer ruft das)
#   ./scripts/litellm-watchdog.sh --install   systemd-Timer alle 5 Minuten
#   ./scripts/litellm-watchdog.sh --uninstall
#   ./scripts/litellm-watchdog.sh --reset     Loopsperre aufheben
#
# Schutzregeln (Warum: andere Agenten teilen sich diese Maschine):
#  * GPU-Sperre: haelt ${XDG_RUNTIME_DIR}/copilot-sm120-gpu.lock ein flock vor
#    (ein anderer Agent arbeitet an der Grafikkarte), passiert nichts.
#  * Laufende Anfragen: vor jedem Neustart wird die Zahl laufender Anfragen der
#    Runtime gelesen (vLLM: vllm:num_requests_running, sglang: num_running_reqs).
#    Ungleich 0 heisst 'verschieben, nicht stoeren'; ist keine Zahl erreichbar,
#    wird ebenfalls verschoben - eine fehlende Zahl ist kein Freifahrtschein.
#  * Loopsperre: nach drei Neustarts ohne Gesundheitsnachweis ist bis zum
#    manuellen --reset Schluss mit Automatik (verhindert Restart-Schleifen).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${LITELLM_PORT:=4000}"
: "${PENNYROYAL_PORT:=8001}"
: "${RUNTIME_PORT:=${PENNYROYAL_PORT:-8001}}"   # hier: 30000 (vLLM)
: "${VLLM_METRICS_PORT:=30001}"                # Weiterleiter, bringt vLLM-Metriken ins Netz
: "${LITELLM_WATCHDOG_SMOKE:=1}"      # 0 = nur liveliness, kein Modellaufruf
: "${LITELLM_WATCHDOG_MAX_RESTARTS:=3}"
state_dir="${STATE_DIR}/litellm-watchdog"
state_file="${state_dir}/fails"
restarts_file="${state_dir}/restarts"
log_file="${state_dir}/watchdog.log"
mkdir -p "${state_dir}"

say() { printf '[%s] %s\n' "$(date -Is)" "$*" | tee -a "${log_file}"; }

gateway_key() {
  # Master-Key aus der lokalen Env-Datei holen; Wert niemals ausgeben.
  local envf="${HOME}/.config/llm-infra/gateway.env"
  [[ -r "${envf}" ]] || return 1
  # shellcheck disable=SC1090
  ( set -a; . "${envf}"; [[ -n "${LITELLM_MASTER_KEY:-}" ]] ) || return 1
  ( set -a; . "${envf}"; printf '%s' "${LITELLM_MASTER_KEY}" )
}

liveliness() { curl -fsS --max-time 10 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" >/dev/null 2>&1; }

smoke() {
  # Eine echte 1-Token-Anfrage durch den Router ( Primaerstecke qwen ). Der
  # Schluessel wird aus gateway.env gelesen und nie in Logs oder Prozesse
  # geschrieben (Dateiinhalt ueber stdin, Header aus Shell-Variable).
  local key
  key="$(gateway_key)" || { say 'WARN smoke uebersprungen: Master-Key nicht lesbar.'; return 0; }
  curl -fsS --max-time 45 \
    -H "Authorization: Bearer ${key}" -H 'Content-Type: application/json' \
    -d '{"model":"qwen3.8-flash-next","messages":[{"role":"user","content":"ping"}],"max_tokens":1}' \
    "http://127.0.0.1:${LITELLM_PORT}/v1/chat/completions" >/dev/null 2>&1
}

runtime_direct_ok() { curl -fsS --max-time 10 "http://127.0.0.1:${RUNTIME_PORT:-30000}/health" >/dev/null 2>&1; }

container_path_ok() {
  # Der Weg, den LiteLLM wirklich nimmt: aus dem Container ueber den Weiterleiter.
  podman exec litellm python3 -c 'import os,urllib.request;b=os.environ["FLASH_NEXT_API_BASE"].rstrip("/");b=b[:-3] if b.endswith("/v1") else b;urllib.request.urlopen(b+"/health",timeout=8)' >/dev/null 2>&1
}

running_requests() {
  # Zahl der laufenden Anfragen. Erst der Weiterleiter (vLLM-Metriken), dann die
  # Runtime selbst: auf diesem Rechner laeuft vLLM, das sglang-Muster bleibt fuer
  # Rechner mit Pennyroyal stehen. Ohne Zahl kommt 'unbekannt' zurueck - der
  # Aufrufer verschiebt dann den Neustart statt zu raten.
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

gpu_lock_busy() {
  # True, wenn das Lock-File existiert UND von jemandem gehalten wird.
  local lock="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/copilot-sm120-gpu.lock"
  [[ -e "${lock}" ]] || return 1
  local fd
  exec 9<>"${lock}" 2>/dev/null || return 1
  if flock -n 9; then flock -u 9; exec 9>&-; return 1; fi
  exec 9>&-
  return 0
}

case "${1:-check}" in
  --install|install)
    install_systemd_units "${HOME}/.config/systemd/user" llm-litellm-watchdog.service llm-litellm-watchdog.timer
    systemd_reload
    systemctl --user enable --now llm-litellm-watchdog.timer
    say 'LiteLLM-Waechter-Timer aktiv (alle 5 Minuten).'
    printf 'Naechster Schritt: systemctl --user list-timers llm-litellm-watchdog.timer\n'
    ;;
  --uninstall|uninstall)
    systemctl --user disable --now llm-litellm-watchdog.timer 2>/dev/null || true
    rm -f "${HOME}/.config/systemd/user/llm-litellm-watchdog.service" "${HOME}/.config/systemd/user/llm-litellm-watchdog.timer"
    systemd_reload
    say 'LiteLLM-Waechter entfernt.'
    ;;
  --reset|reset)
    rm -f "${state_file}" "${restarts_file}"
    say 'Zaehler und Loopsperre zurueckgesetzt.'
    ;;
  check)
    fails="$(cat "${state_file}" 2>/dev/null || echo 0)"
    restarts="$(cat "${restarts_file}" 2>/dev/null || echo 0)"
    if liveliness && { [[ "${LITELLM_WATCHDOG_SMOKE}" != 1 ]] || smoke; }; then
      [[ "${fails}" != 0 || "${restarts}" != 0 ]] && say 'Gateway wieder gesund; Zaehler zurueckgesetzt.'
      echo 0 > "${state_file}"; echo 0 > "${restarts_file}"
      exit 0
    fi
    fails=$((fails + 1)); echo "${fails}" > "${state_file}"
    say "FEHLER: Gateway-Pruefung fehlgeschlagen (Versuch ${fails}; liveliness+smoke)."
    say '  Erste Hilfe: journalctl --user -u litellm.service -n 120 --no-pager'
    say '  Dann:        ./scripts/doctor.sh'
    # 2026-11-23: 89 Fehlschlaege, weil der Weiterleiter nach dem Boot nur auf
    # Loopback lauschte; ein LiteLLM-Neustart heilt das nicht. Erst die Kette pruefen.
    if liveliness && runtime_direct_ok && ! container_path_ok; then
      say 'DIAGNOSE: Runtime direkt gesund, aus dem LiteLLM-Container nicht erreichbar -> Neustart llm-vllm-forwarder.'
      systemctl --user restart llm-vllm-forwarder.service || say 'Weiterleiter-Neustart fehlgeschlagen.'
      sleep 3
      container_path_ok && { say 'Weiterleiter-Pfad wieder erreichbar.'; exit 0; }
    fi
    if (( restarts >= LITELLM_WATCHDOG_MAX_RESTARTS )); then
      say 'LOOPSPERRE: bereits '"${restarts}"' Neustarts ohne Gesundheit - keine Automatik mehr.'
      say '  Manuell pruefen und dann freigeben: ./scripts/litellm-watchdog.sh --reset'
      exit 1
    fi
    if gpu_lock_busy; then
      say 'GPU-Sperre belegt (copilot-sm120-gpu.lock): kein Eingriff in dieser Runde.'
      exit 0
    fi
    running="$(running_requests)"
    if [[ "${running}" == 'unbekannt' || "${running%.*}" != "0" ]]; then
      say 'Neustart verschoben: laufende Anfragen ('"${running}"') oder keine Zahl erreichbar - ohne Zahl wird nicht neu gestartet.'
      exit 0
    fi
    restarts=$((restarts + 1)); echo "${restarts}" > "${restarts_file}"
    say 'Neustart nur von litellm.service (Versatz '"${restarts}"'/'"${LITELLM_WATCHDOG_MAX_RESTARTS}"'; Runtime unbertroffen). '
    systemctl --user restart litellm.service || say 'Neustart fehlgeschlagen; Journal pruefen.'
    sleep 10
    if liveliness; then
      say 'Litellm nach Neustart wieder lebendig.'
      echo 0 > "${state_file}"
    else
      say 'Nach wie vor krank; naechster Timer-Lauf entscheidet neu.'
    fi
    exit 1
    ;;
  *)
    printf 'usage: %s [check|--install|--uninstall|--reset]\n' "$0" >&2
    exit 2
    ;;
esac
