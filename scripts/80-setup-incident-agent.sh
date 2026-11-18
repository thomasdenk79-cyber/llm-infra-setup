#!/usr/bin/env bash
# Incident-Agent einrichten (Demo-Pipeline: Alarm -> KI-Analyse -> Ticket -> Kunde).
#
# Erzeugt die Quadlet-Unit des Agenten, stellt den Gateway-Schluessel aus und
# rollt die Einheit aus. Der Agent hoert nur im Beobachtungsnetz auf :9104
# (kein PublishPort - Geraet gehoert dem Modell, und die Gegenstelle ist der
# Alertmanager im selben Netz).
#
#   ./scripts/80-setup-incident-agent.sh            ausrollen (idempotent)
#   ./scripts/80-setup-incident-agent.sh --check    Pruefung ohne Aenderungen
#   ./scripts/80-setup-incident-agent.sh --demo     Beispiel-Alarm ausloesen
#
# Nach dem ersten Ausrollen: ./scripts/60-install-monitoring.sh erneut laufen
# lassen, damit Alertmanager-Empfaenger und Regeln aktiv werden.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${INCIDENT_AGENT_IMAGE:=docker.io/library/python:3.12-alpine}"
: "${AGENT_MODEL:=qwen3.8-flash-next}"
staedir="${LLM_INCIDENT_STATE_DIR:-${HOME}/.local/share/llm-infra/incident}"
umweltdatei="${SECRETS_DIR:-${HOME}/.config/llm-infra}/incident-agent.env"

case "${1:-install}" in
  --check)
    fehl=0
    [[ -f "${root}/quadlet/incident-agent.container" ]] || { echo 'FEHLT: quadlet/incident-agent.container (erst Generator laufen lassen)'; fehl=1; }
    unit_is_active incident-agent.container || { echo 'FEHLT: Unit laeuft nicht. Naechster Befehl: ./scripts/80-setup-incident-agent.sh'; fehl=1; }
    [[ -r "${umweltdatei}" ]] || { echo "FEHLT: ${umweltdatei}"; fehl=1; }
    if have curl; then
      upWert="$(curl -s --max-time 5 "http://127.0.0.1:9090/api/v1/query?query=up%7Bjob%3D%22incident-agent%22%7D" | python3 -c 'import json,sys
try:
    r = json.load(sys.stdin)["data"]["result"]
    print(r[0]["value"][1] if r else "keine Messreihe")
except Exception as exc:
    print("Fehler", exc)' 2>/dev/null || echo 'Prometheus nicht erreichbar')"
      echo "agent-erreichbar laut Prometheus: ${upWert}"
      [[ "${upWert}" == "1" ]] || fehl=1
    fi
    exit "${fehl}"
    ;;
  --demo)
    podman inspect llm-incident-agent >/dev/null 2>&1 || die "Agent-Container laeuft nicht. Naechster Befehl: ./scripts/80-setup-incident-agent.sh"
    # Demo-Alarm direkt beim Agenten einspielen (wie ein Alertmanager-Webhook);
    # der Zugriff laeuft durch den Container selbst, denn der Name ist nur im
    # Beobachtungsnetz aufloesbar.
    podman exec llm-incident-agent python3 -c '
import json, urllib.request
weck = {"alert": {"status": "firing",
        "labels": {"alertname": "DemoAusfall", "name": "litellm", "severity": "critical"},
        "annotations": {"summary": "Gateway antwortet nicht auf /health/liveliness"}}}
anfrage = urllib.request.Request("http://127.0.0.1:9104/replay",
    data=json.dumps(weck).encode(), headers={"Content-Type": "application/json"})
print(urllib.request.urlopen(anfrage, timeout=10).read().decode())' \
      || die "Demo konnte nicht uebermittelt werden - laeuft der Agent? Naechster Befehl: ./scripts/80-setup-incident-agent.sh --check"
    echo
    cat <<'HINWEIS'
Beispielalarm uebermittelt. Ergebnisse nach 1-2 Minuten:
  Agent-Journal: podman logs --tail 60 llm-incident-agent
  Ticket-Auszug:    podman exec llm-incident-agent python3 -c "import sqlite3 as s; print(s.connect('/var/lib/incident-agent/tickets.db').execute('SELECT id,alertname,zustand,eta_minuten FROM tickets ORDER BY id DESC LIMIT 5').fetchall())"
  Grafana: Ordner "LLM Infrastructure" -> Incident-Analyse
HINWEIS
    exit 0
    ;;
  install) : ;;
  *) die "Unbekanntes Kommando '${1}'. Naechster Befehl: $0 --help" ;;
esac

# --- Bild vorbereiten --------------------------------------------------------
# Der Digest wird mitgeschrieben, damit ein Nachbau exakt dasselbe Bild nimmt.
# Im Prueflauf (LLM_DRIFT) wird nichts gezogen, aber der Digest des lokalen
# Bildes gelesen - sonst erzeugte der Generator eine andere Unit als committet.
if [[ "${LLM_DRIFT:-0}" != 1 ]]; then
  podman image exists "${INCIDENT_AGENT_IMAGE}" || {
    log "Bild wird gezogen: ${INCIDENT_AGENT_IMAGE}"
    podman pull -q "${INCIDENT_AGENT_IMAGE}" >/dev/null
  }
fi
digest="$(podman image inspect "${INCIDENT_AGENT_IMAGE}" --format '{{.Digest}}' 2>/dev/null || true)"
[[ "${digest}" == sha256:* ]] || digest=''
bild="${INCIDENT_AGENT_IMAGE}${digest:+@${digest}}"

install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/incident-agent.container" <<UNIT
# GENERIERT von scripts/80-setup-incident-agent.sh. Aendern im Generator, nicht hier.
[Unit]
Description=llm-infra Incident-Agent (KI-Vorfallsanalyse, Demo)
After=llm-observability-network.service llm-inference-network.service

[Container]
Image=${bild}
ContainerName=llm-incident-agent
Network=llm-observability.network
Network=llm-inference.network
# Code und Adapterdefinition vom Repo (lesend), Zustand ins Home-Verzeichnis.
Volume=@CONFIG_ROOT@/scripts/incident-agent:/app:ro
Volume=@CONFIG_ROOT@/config/monitoring/incident-agent-adapters.json:/etc/incident-agent/adapters.json:ro
Volume=%h/.local/share/llm-infra/incident:/var/lib/incident-agent:Z,U
EnvironmentFile=%h/.config/llm-infra/incident-agent.env
# Kein PublishPort: Gegenstelle ist der Alertmanager im eigenen Netz;
# Sichtbarkeit nach aussen uebernehmen Grafana und die Kennzahlen.
Exec=python3 /app/server.py

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
log 'Unit erzeugt: quadlet/incident-agent.container'

if [[ "${LLM_DRIFT:-0}" == 1 ]]; then
  log 'LLM_DRIFT: Zugangsvergabe und Ausrollen uebersprungen.'
  exit 0
fi

# --- Zugangswerte -------------------------------------------------------------
# Der Agent redet mit dem Modell nur ueber das eigene Gateway - wie jede andere
# Anwenderin auch, mit einem persoenlichen Schluessel aus 71-gateway-keys.sh.
install -d -m 0700 "$(dirname "${umweltdatei}")"
if [[ ! -r "${umweltdatei}" ]]; then
  log "Schluessel fuer den Agenten wird ausgestellt (Alias incident-agent)."
  schluessel="$(chat_service_key incident-agent)"
  umask 077
  cat > "${umweltdatei}" <<ENV
# Erzeugt von scripts/80-setup-incident-agent.sh - enthaelt Zugangswerte, nicht committen.
GATEWAY_KEY=${schluessel}
AGENT_MODEL=${AGENT_MODEL}
GATEWAY_URL=http://litellm:4000
LOKI_URL=http://loki:3100
PROM_URL=http://prometheus:9090
AGENT_PORT=9104
STATE_DIR=/var/lib/incident-agent
ENV
  chmod 600 "${umweltdatei}"
  log "Zugangsdatei angelegt: ${umweltdatei}"
else
  log "Zugangsdatei vorhanden, bleibt unangetastet: ${umweltdatei}"
fi
install -d -m 0755 "${staedir}"

# --- Ausrollen ----------------------------------------------------------------
install_units incident-agent.container
systemd_reload
start_units incident-agent.container
log 'Fertig. Pruefen: ./scripts/80-setup-incident-agent.sh --check   Demo: ./scripts/80-setup-incident-agent.sh --demo'
