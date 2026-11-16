#!/usr/bin/env bash
# Portal (gethomepage) einrichten: Konfiguration an den Live-Ordner uebergeben
# und die Quadlet-Unit erzeugen.
#
# Einzelne Quelle der Wahrheit fuer die erlaubten Hosts ist config/host.env
# (Variable HOMEPAGE_ALLOWED_HOSTS, Default: Loopback auf Port 3002). Der
# oeffentliche Zugang der Kollegen haengt hinter Caddy auf dem Gateway-Rechner;
# dessen Homepage-Block setzt den Host-Header auf die Upstream-Adresse
# ("header_up Host {upstream_hostport}" in config/gateway/Caddyfile.template),
# deshalb prueft Homepage den Loopback-Wert 127.0.0.1:3002 und keinen
# Gateway-Namen. Werte fuer 8443 oder LAN-Adressen gehoeren nicht mehr hierher:
# der LAN-HTTPS-Proxy ist durch den Gateway-Tunnel ersetzt.
#
# Die Unit-Datei quadlet/homepage.container wird hier geschrieben und traegt
# den Header "GENERIERT von". Aendern am Generator, nicht an der Datei -
# ./scripts/check-drift.sh (make drift) prueft genau das.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
# shellcheck disable=SC1091  # Rechnerdatei, absichtlich ausserhalb von Git
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

homepage_port=3002   # muss zu PublishPort in der Unit-Datei passen
homepage_allowed_hosts="$(printf '%s' "${HOMEPAGE_ALLOWED_HOSTS:-}" | tr -d '[:space:]')"
if [[ -z "${homepage_allowed_hosts}" ]]; then
  homepage_allowed_hosts="127.0.0.1:${homepage_port},localhost:${homepage_port}"
fi
# Zeichenerlaubnis statt Regex: die bash-ERE scheitert an den eckigen Klammern
# der IPv6-Notation, und der Wert landet ohne Umwege in einer Unit-Datei.
# Whitespace wird vorher entfernt, weil Homepage selbst nur auf Komma trennt -
# ein ' host' in der Liste wuerde sonst stillschweigend nie passen.
homepage_allowed_hosts_clean="$(printf '%s' "${homepage_allowed_hosts}" | tr -cd -- '-A-Za-z0-9.,:*_[]')"
[[ "${homepage_allowed_hosts_clean}" == "${homepage_allowed_hosts}" ]] || \
  die "HOMEPAGE_ALLOWED_HOSTS enthaelt ungueltige Zeichen: '${homepage_allowed_hosts}'. Erlaubt sind host:port-Paare durch Komma getrennt, oder '*' fuer keine Pruefung."

install -d -m 0755 "${root}/quadlet"
config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra/homepage"
install -d -m 0755 "${config_dir}"
# Der Container liest /app/config aus diesem Ordner: die versionierten YAMLs
# sind die einzige Quelle, Handaenderungen am Live-Ordner sind ueberschrieben.
cp -f "${root}"/config/homepage/*.yaml "${config_dir}/"

sed "s|__HOMEPAGE_ALLOWED_HOSTS__|${homepage_allowed_hosts}|" > "${root}/quadlet/homepage.container" <<'UNIT'
# GENERIERT von scripts/60-install-homepage.sh - dort ändern, nicht hier.
[Unit]
Description=LLM Infrastructure Homepage portal
After=llm-observability-network.service
Wants=llm-observability-network.service

[Container]
Image=ghcr.io/gethomepage/homepage:v2.4.0
ContainerName=llm-homepage
Network=llm-observability.network
PublishPort=127.0.0.1:3002:3000
# Erlaubte Host-Header: kommen aus config/host.env (HOMEPAGE_ALLOWED_HOSTS).
# Jeder andere Host antwoordet mit 400 - Pruefung in src/middleware.js der
# gepinnten Version v2.4.0.
Environment=HOMEPAGE_ALLOWED_HOSTS=__HOMEPAGE_ALLOWED_HOSTS__
Volume=%h/.config/llm-infra/homepage:/app/config:Z,U

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT

log "Homepage-Quadlet erzeugt: http://127.0.0.1:${homepage_port}/, erlaubte Hosts: ${homepage_allowed_hosts}"
log 'Konfiguration kopiert nach '"${config_dir}"' - damit beides wirkt, Unit neu laden und Portal neu starten:'
log '  systemctl --user daemon-reload && systemctl --user restart homepage.service'
