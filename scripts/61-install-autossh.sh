#!/usr/bin/env bash
# Optionaler Wartungstunnel (Reverse-SSH), nur fuer Fernzugriff von aussen.
#
# VORBEREITUNG durch den Betreiber:
#   1. scp ~/.ssh/id_ed25519.pub auf den Gegenrechner in authorized_keys legen
#   2. cp config/autossh.env.example config/autossh.env und echten Host eintragen
#   3. ./scripts/61-install-autossh.sh --check     Verbindungstest
#   4. ./scripts/61-install-autossh.sh && systemctl --user start llm-autossh.service
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
: "${AUTOSSH_LOCAL_PORT:=4000}"
: "${AUTOSSH_SSH_KEY:=%h/.ssh/id_ed25519}"
key_path="${AUTOSSH_SSH_KEY/\%h/${HOME}}"
state_dir="${HOME}/.local/share/llm-infra/ssh"

need_cmd podman 'Jetzt ausführen: make install'
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
touch "${state_dir}/known_hosts" 2>/dev/null || { install -d -m 0700 "${state_dir}"; touch "${state_dir}/known_hosts"; }
chmod 0600 "${state_dir}/known_hosts"

if [[ "${1:-}" == "--check" ]]; then
  echo "Teste Verbindung ${AUTOSSH_REMOTE_USER}@${AUTOSSH_REMOTE_HOST}:${AUTOSSH_REMOTE_PORT} ..."
  ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new \
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
AddHost=host.containers.internal:host-gateway
Volume=${key_path}:/ssh/id_ed25519:ro,Z
Volume=${state_dir}:/ssh/persist:Z
Exec=-M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes \\
    -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/ssh/persist/known_hosts \\
    -i /ssh/id_ed25519 -p ${AUTOSSH_REMOTE_PORT} \\
    -R 127.0.0.1:${AUTOSSH_REMOTE_BIND_PORT}:host.containers.internal:${AUTOSSH_LOCAL_PORT} \\
    ${AUTOSSH_REMOTE_USER}@${AUTOSSH_REMOTE_HOST}

[Service]
Restart=on-failure
RestartSec=60
StartLimitIntervalSec=600
StartLimitBurst=10

[Install]
WantedBy=default.target
UNIT
log 'Tunnel-Unit erzeugt. Start (bewusst): systemctl --user daemon-reload && systemctl --user start llm-autossh.service'
