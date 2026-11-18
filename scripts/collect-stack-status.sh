#!/usr/bin/env bash
# Stack-Status als Kennzahlen fuer die Status-Seiten in Grafana.
#
# Liefert llm_service_* (Up/Down, Grund, Startzeit, Wiederherstellungs-Schaetzung)
# und llm_customer_status_* (Kundenansicht) in den Textfile-Ordner des
# node_exporters. Den Grund kennt nur dieser Rechner (Podman-Zustand, User-Units),
# deshalb entsteht er hier und nicht in Prometheus. Liegt ein offener Vorfall des
# Incident-Agenten vor (state-Datei customer-status.json), stammt die Schaetzung
# von ihm; sonst gilt der Erfahrungswert, und ohne alles steht -1 (= unbekannt).
#
#   ./scripts/collect-stack-status.sh            eine Sammlung, atomar geschrieben
#   ./scripts/collect-stack-status.sh --pruefen  nur anzeigen, nichts schreiben
#
# Laeuft alle 30 s über systemd/llm-stack-status.timer (Verzahnung mit
# scripts/60-install-monitoring.sh). Zerstoerungsfrei: einzelne Teilpfade duerfen
# scheitern und fuehren zu reason=unknown, nie zum Abbruch.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "${root}/lib/common.sh"
# shellcheck source=units.sh
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
TEXTFILE_DIR="${LLM_NODE_EXPORTER_TEXTFILE:-${HOME}/.local/share/llm-infra/node-exporter/textfile}"
STATUS_DATEI="${LLM_INCIDENT_STATE_DIR:-${HOME}/.local/share/llm-infra/incident}/customer-status.json"
RUNTIME_PORT="${RUNTIME_PORT:-30000}"
dry_run=0
[[ "${1:-}" == "--pruefen" ]] && dry_run=1

raw="$(mktemp)"; tmp="$(mktemp)"
trap 'rm -f "${raw}" "${tmp}"' EXIT
emit() { printf '%s\n' "$1" >> "${raw}"; }

# Erfahrungswerte (Sekunden), wie lange ein geplanter Neustart dieses Dienstes
# dauert. Deckt den ueblichen Rollout dieses Stapels ab; der Incident-Agent
# ueberschreibt sie bei echten Vorfällen mit seiner Analyse.
eta_fuer() {
  case "$1" in
    runtime) echo 900 ;;
    litellm|open-webui) echo 60 ;;
    litellm-postgres|loki) echo 45 ;;
    grafana|prometheus|alloy|alertmanager|llm-proxy|reverse-tunnel) echo 30 ;;
    *) echo 20 ;;
  esac
}

# Zustand eines Containers; liefert "status started epoch image".
# Quadlet-Container heissen entweder wie die Unit oder systemd-<unit> (ohne
# ausdruecklichen ContainerName) - beide Namen werden probiert.
container_info() {
  local c info
  for c in "$1" "systemd-$1" "llm-$1"; do
    info="$(podman inspect --type container "${c}" \
      --format '{{.State.Status}}\t{{.State.StartedAt}}\t{{.Config.Image}}' 2>/dev/null)" || continue
    printf '%s\n' "${info}"
    return 0
  done
  printf 'missing\t0\tn/a\n'
}

epoch_von() {  # RFC3339 -> Sekunde; Nullzeit und Unsinniges -> 0
  local t="$1"
  case "$t" in 0001-*|'') echo 0; return ;; esac
  # Podman liefert Nanosekunden und teils eine Zeitzonen-Abkuerzung hinter der
  # Offsetangabe - beides versteht `date -d` nicht, also vorab abschneiden.
  t="$(printf '%s' "$t" | sed -E 's/[[:space:]]+[A-Za-z]{2,5}$//; s/\.[0-9]+//; s/[[:space:]]+$//')"
  date -d "$t" +%s 2>/dev/null || echo 0
}

# --- Containerdienste --------------------------------------------------------
# Die Namen sind der Vertrag mit den Grafana-Seiten (spec in .omo-work):
container_dienste=(grafana prometheus loki alloy alertmanager dozzle homepage
                   llm-proxy litellm litellm-postgres open-webui wiki
                   llm-node-exporter llm-gpu-exporter incident-agent)
for dienst in "${container_dienste[@]}"; do
  IFS=$'\t' read -r state gestartet image <<<"$(container_info "${dienst}")"
  up=0; grund="${state}"
  [[ "${state}" == "running" ]] && up=1
  start_epoch=0
  if [[ "${state}" == "running" ]]; then
    start_epoch="$(epoch_von "${gestartet}")"
  fi
  schaetzung=0
  if [[ "${up}" == 0 ]]; then
    if [[ "${grund}" == "missing" ]]; then grund='container fehlt'; fi
    schaetzung="$(eta_fuer "${dienst}")"
  fi
  emit "llm_service_up{name=\"${dienst}\"} ${up}"
  emit "llm_service_info{name=\"${dienst}\",state=\"${state}\",reason=\"${grund}\",image=\"${image}\"} 1"
  emit "llm_service_start_time_seconds{name=\"${dienst}\"} ${start_epoch}"
  emit "llm_service_downtime_estimate_seconds{name=\"${dienst}\"} ${schaetzung}"
done

# --- Inferenz-Laufzeit -------------------------------------------------------
# Kein Unit-Zugriff moeglich (die aktive Laufzeit kann ein unorganisierter
# Container sein), also Messung am Port: 200 auf /health gilt als betriebsbereit.
code="$(curl -s -o /dev/null -m 3 -w '%{http_code}' "http://127.0.0.1:${RUNTIME_PORT}/health" 2>/dev/null || echo 000)"
up=0; [[ "${code}" == "200" ]] && up=1
start_epoch=0
if [[ "${up}" == 1 ]]; then
  laufender="$(podman ps -n 1 --filter "publish=${RUNTIME_PORT}" --format '{{.Names}}' 2>/dev/null || true)"
  if [[ -n "${laufender}" ]]; then
    gestartet="$(podman inspect --type container "${laufender}" --format '{{.State.StartedAt}}' 2>/dev/null || true)"
    start_epoch="$(epoch_von "${gestartet}")"
  fi
fi
schaetzung=0
[[ "${up}" == 0 ]] && schaetzung="$(eta_fuer runtime)"
emit "llm_service_up{name=\"runtime\"} ${up}"
emit "llm_service_info{name=\"runtime\",state=\"probe\",reason=\"HTTP ${code} auf :${RUNTIME_PORT}/health\",image=\"gemäss host.env\"} 1"
emit "llm_service_start_time_seconds{name=\"runtime\"} ${start_epoch}"
emit "llm_service_downtime_estimate_seconds{name=\"runtime\"} ${schaetzung}"

# --- User-Units ohne Container ------------------------------------------------
for paar in "vllm-forwarder:llm-vllm-forwarder" "reverse-tunnel:llm-reverse-tunnel"; do
  dienst="${paar%%:*}"; unit="${paar##*:}"
  if unit_exists "${unit}.service"; then
    if systemctl --user is-active --quiet "${unit}.service"; then up=1; state="running"; else up=0; state="failed"; fi
  else
    up=0; state="missing"
  fi
  start_epoch=0
  schaetzung=0
  if [[ "${up}" == 0 ]]; then
    schaetzung="$(eta_fuer "${dienst}")"
    [[ "${state}" == "missing" ]] && state="not-installed"
  else
    start_epoch="$(systemctl --user show "${unit}.service" -p ExecMainStartTimestamp --value 2>/dev/null | xargs -r date -d 2>/dev/null +%s || echo 0)"
    : "${start_epoch:=0}"
    [[ "${start_epoch}" =~ ^[0-9]+$ ]] || start_epoch=0
  fi
  emit "llm_service_up{name=\"${dienst}\"} ${up}"
  emit "llm_service_info{name=\"${dienst}\",state=\"${state}\",reason=\"user-unit ${state}\",image=\"host\"} 1"
  emit "llm_service_start_time_seconds{name=\"${dienst}\"} ${start_epoch}"
  emit "llm_service_downtime_estimate_seconds{name=\"${dienst}\"} ${schaetzung}"
done

# --- Kundenstatus und Vorfallsoffenheit --------------------------------------
# Der Incident-Agent schreibt customer-status.json; ohne ihn (oder ohne
# Vorfall) gilt die gruene Default-Meldung. Zeitstempel der Datei mitgeben,
# damit die Kundenseite erkennen kann, wie frisch die Aussage ist.
if [[ -r "${STATUS_DATEI}" ]] && have python3; then
  python3 - "${STATUS_DATEI}" <<'PY' >> "${raw}" || emit "llm_customer_status_info{service=\"siemens-edi-oftp\",state=\"ok\",message=\"Alle Systeme betriebsbereit\",eta=\"-\"} 1"
import json, sys
try:
    status = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    print('llm_customer_status_info{service="siemens-edi-oftp",state="ok",message="Alle Systeme betriebsbereit",eta="-"} 1')
    raise SystemExit(0)
dienste = status.get("services") or {}
if not dienste:
    print('llm_customer_status_info{service="siemens-edi-oftp",state="ok",message="Alle Systeme betriebsbereit",eta="-"} 1')
for name, eintrag in dienste.items():
    feld = lambda k: str(eintrag.get(k, "-")).replace('"', "'")
    print('llm_customer_status_info{service="%s",state="%s",message="%s",eta="%s"} 1'
          % (name, feld("state"), feld("message"), feld("eta")))
offen = int(status.get("open") or 0)
if offen > 0:
    schwer = str(status.get("severity") or "warning").replace('"', "'")
    print('llm_incident_open{severity="%s"} 1' % schwer)
PY
else
  emit "llm_customer_status_info{service=\"siemens-edi-oftp\",state=\"ok\",message=\"Alle Systeme betriebsbereit\",eta=\"-\"} 1"
fi

# Alter der Agenten-Datei: zeigt der Kundenseite, wie frisch die Aussage ist.
datei_alter=0
if [[ -r "${STATUS_DATEI}" ]]; then
  seit="$(stat -c %Y "${STATUS_DATEI}" 2>/dev/null || true)"
  [[ "${seit}" =~ ^[0-9]+$ ]] && datei_alter=$(( $(date +%s) - seit ))
fi
emit "llm_stack_status_collect_age_seconds ${datei_alter}"

# --- Ausgeben -----------------------------------------------------------------
if (( dry_run )); then
  cat "${raw}"
  exit 0
fi
install -d -m 0755 "${TEXTFILE_DIR}"
# mktemp legt die Datei 0600 an - der node_exporter (andere User-Kennung im
# Container) muss sie lesen koennen, deshalb beim Verschieben auf 0644 setzen.
chmod 0644 "${raw}"
mv -f "${raw}" "${TEXTFILE_DIR}/stack-status.prom"
touch "${TEXTFILE_DIR}/stack-status.prom"   # Zeitstempel fuer den Frische-Alarm
log 'Stack-Status geschrieben: '"${TEXTFILE_DIR}/stack-status.prom"
