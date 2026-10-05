#!/usr/bin/env bash
# Optionaler Wartungstunnel (Reverse-SSH), nur fuer Fernzugriff von aussen.
#
# VORBEREITUNG durch den Betreiber:
#   1. eingeschraenkten Public Key am Gateway hinterlegen
#   2. config/autossh.env mit Host, Benutzer und Key-Pfad ausfuellen
#   3. Gateway-Host-Key in ~/.local/share/llm-infra/ssh/known_hosts verifizieren
#   4. ./scripts/61-install-autossh.sh --check     Verbindungstest
#   5. ./scripts/61-install-autossh.sh && systemctl --user start llm-autossh.service
#
# Ohne echten Gegenrechner wird nichts installiert: ein Platzhaltertunnel
# wuerde nur eine dauernde Fehler schleife erzeugen.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/autossh.env" ]] && source "${root}/config/autossh.env"
: "${AUTOSSH_REMOTE_HOST:=}"
: "${AUTOSSH_REMOTE_USER:=llm}"
: "${AUTOSSH_REMOTE_PORT:=22}"
: "${AUTOSSH_REMOTE_BIND_PORT:=4000}"
: "${AUTOSSH_REMOTE_GRAFANA_PORT:=3000}"
: "${AUTOSSH_REMOTE_HOMEPAGE_PORT:=3002}"
: "${AUTOSSH_LOCAL_HOST:=127.0.0.1}"
: "${AUTOSSH_LOCAL_PORT:=4000}"
: "${AUTOSSH_LOCAL_GRAFANA_PORT:=3000}"
: "${AUTOSSH_LOCAL_HOMEPAGE_PORT:=3002}"
: "${AUTOSSH_SSH_KEY:=%h/.ssh/id_ed25519}"
key_path="${AUTOSSH_SSH_KEY/\%h/${HOME}}"
state_dir="${HOME}/.local/share/llm-infra/ssh"
if [[ "${key_path}" == "${HOME}/"* ]]; then
  unit_key_path="%h${key_path#"${HOME}"}"
else
  unit_key_path="${key_path}"
fi

need_cmd podman 'Jetzt ausführen: make install'
install -d -m 0700 "${state_dir}"
if [[ -z "${AUTOSSH_REMOTE_HOST}" || "${AUTOSSH_REMOTE_HOST}" == example.net ]]; then
  cat >&2 <<MSG
ABBRUCH: Es ist kein echter Gegenrechner konfiguriert.
So geht es richtig:
  cp config/autossh.env.example config/autossh.env
  nano config/autossh.env        # AUTOSSH_REMOTE_HOST=dein-server.example
  ./scripts/61-install-autossh.sh
MSG
  exit 1
fi
[[ -f "${key_path}" ]] || { echo "ABBRUCH: SSH-Schluessel nicht gefunden: ${key_path}" >&2; exit 1; }
touch "${state_dir}/known_hosts"
chmod 0600 "${state_dir}/known_hosts"

if [[ "${1:-}" == "--check" ]]; then
  echo "Teste Verbindung ${AUTOSSH_REMOTE_USER}@${AUTOSSH_REMOTE_HOST}:${AUTOSSH_REMOTE_PORT} ..."
  ssh -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes \
      -o UserKnownHostsFile="${state_dir}/known_hosts" -i "${key_path}" -p "${AUTOSSH_REMOTE_PORT}" \
      "${AUTOSSH_REMOTE_USER}@${AUTOSSH_REMOTE_HOST}" 'echo Verbindung OK'
  exit $?
fi

if ! podman image exists localhost/llm-autossh:local; then
  run podman build -t localhost/llm-autossh:local "${root}/containers/autossh"
fi
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/llm-autossh.container" <<UNIT
# GENERIERT von scripts/61-install-autossh.sh.
# Es wird nur EIN Schluessel eingelaesen, nicht der ganze ~/.ssh-Bestand.
[Unit]
Description=Wartungstunnel zum LiteLLM-Gateway
After=network-online.target litellm.service

[Container]
Image=localhost/llm-autossh:local
ContainerName=llm-autossh
Network=host
Volume=${unit_key_path}:/ssh/id_ed25519:ro,Z
Volume=%h/.local/share/llm-infra/ssh/known_hosts:/ssh/known_hosts:ro,Z
Environment=AUTOSSH_GATETIME=0
Exec=-M 0 -N -o BatchMode=yes -o IdentitiesOnly=yes -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \\
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/ssh/known_hosts \\
    -i /ssh/id_ed25519 -p ${AUTOSSH_REMOTE_PORT} \\
    -R 127.0.0.1:${AUTOSSH_REMOTE_BIND_PORT}:${AUTOSSH_LOCAL_HOST}:${AUTOSSH_LOCAL_PORT} \\
    -R 127.0.0.1:${AUTOSSH_REMOTE_GRAFANA_PORT}:127.0.0.1:${AUTOSSH_LOCAL_GRAFANA_PORT} \\
    -R 127.0.0.1:${AUTOSSH_REMOTE_HOMEPAGE_PORT}:127.0.0.1:${AUTOSSH_LOCAL_HOMEPAGE_PORT} \\
    ${AUTOSSH_REMOTE_USER}@${AUTOSSH_REMOTE_HOST}

[Service]
Restart=on-failure
RestartSec=60
StartLimitIntervalSec=600
StartLimitBurst=10

[Install]
WantedBy=default.target
UNIT
render_unit llm-autossh.container
systemd_reload
log 'Tunnel-Unit installiert. Start (bewusst): systemctl --user start llm-autossh.service'
