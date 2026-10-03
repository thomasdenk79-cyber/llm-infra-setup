#!/usr/bin/env bash
# Optional: Komodo Periphery (ferne Container-Verwaltung).
#
# Die Periphery braucht
#   * einen echten Server (kein Platzhalter)
#   * einen API-Schluessel in ~/.config/llm-infra/komodo.env
#   * Lesenden Zugriff auf den Podman-Socket, um Container zu steuern
#
# Ohne diese drei Punkte wird nichts installiert, damit keine Unit mit
# Beispielwerten im Autostart landet.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/komodo.env" ]] && source "${root}/config/komodo.env"
: "${KOMODO_IMAGE:=ghcr.io/moghtech/komodo-periphery:2.3.3}"
: "${KOMODO_SERVER_URL:=}"
: "${KOMODO_PERIPHERY_NAME:=$(hostname)}"
: "${KOMODO_PORT:=8120}"
komodo_env="${SECRETS_DIR}/komodo.env"

if [[ -z "${KOMODO_SERVER_URL}" || "${KOMODO_SERVER_URL}" == https://komodo.example.net ]]; then
  cat >&2 <<MSG
ABBRUCH: Kein echter Komodo-Server konfiguriert.
Vorbereitung:
  cp config/komodo.env.example config/komodo.env      # Rechnername und URL eintragen
  mkdir -p ~/.config/llm-infra
  printf 'PERIPHERY_API_KEY=dein-schluessel\n' > ~/.config/llm-infra/komodo.env
  chmod 600 ~/.config/llm-infra/komodo.env
Die Schluesselbezeichnung steht in der Komodo-Dokumentation deines Servers;
bitte dort nachlesen und ggf. in dieser Datei anpassen.
MSG
  exit 1
fi
[[ -f "${komodo_env}" ]] || { echo "ABBRUCH: ${komodo_env} fehlt (PERIPHERY_API_KEY)." >&2; exit 1; }
grep -qE '^(PERIPHERY_API_KEY|KOMODO_API_KEY)=' "${komodo_env}" \
  || { echo "ABBRUCH: in ${komodo_env} steht kein PERIPHERY_API_KEY." >&2; exit 1; }
systemctl --user is-active --quiet podman.socket \
  || { echo 'ABBRUCH: podman.socket laeuft nicht. Naechster Schritt: systemctl --user enable --now podman.socket' >&2; exit 1; }
install -d -m 0755 "${root}/quadlet" "${HOME}/.local/share/komodo"
cat > "${root}/quadlet/komodo-periphery.container" <<UNIT
# GENERIERT von scripts/62-install-komodo.sh.
[Unit]
Description=Komodo Periphery Agent
After=network-online.target

[Container]
Image=${KOMODO_IMAGE}
ContainerName=komodo-periphery
PublishPort=127.0.0.1:${KOMODO_PORT}:8120
EnvironmentFile=${komodo_env}
Environment=PERIPHERY_HOST=${KOMODO_PERIPHERY_NAME}
Environment=PERIPHERY_PORT=8120
Environment=PERIPHERY_DOCKER_SOCK_LOCATION=/var/run/docker.sock
Volume=%t/podman/podman.sock:/var/run/docker.sock
Volume=${HOME}/.local/share/komodo:/etc/komodo:Z

[Service]
Restart=on-failure
RestartSec=30

[Install]
WantedBy=default.target
UNIT
log 'Komodo-Periphery-Unit erzeugt.'
log 'Start (bewusst): systemctl --user daemon-reload && systemctl --user start komodo-periphery.service'
log 'Sicherheit: Die Periphery kann Container starten und stoppen. URL und Firewall vorher pruefen (docs/security.md).'
