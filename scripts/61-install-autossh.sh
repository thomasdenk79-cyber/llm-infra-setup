#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; source "$root/lib/common.sh"
[[ -f "$root/config/autossh.env" ]] && source "$root/config/autossh.env" || true
: "${AUTOSSH_REMOTE_HOST:=example.net}"; : "${AUTOSSH_REMOTE_USER:=llm}"; : "${AUTOSSH_REMOTE_PORT:=22}"; : "${AUTOSSH_REMOTE_BIND_PORT:=4000}"; : "${AUTOSSH_LOCAL_PORT:=4000}"; : "${AUTOSSH_SSH_KEY:=%h/.ssh/id_ed25519}"
install -d "$root/quadlet"; cat > "$root/quadlet/llm-autossh.container" <<UNIT
[Unit]
Description=Reverse SSH tunnel to LiteLLM
After=network-online.target litellm.service
[Container]
Image=docker.io/library/alpine:3.20
ContainerName=llm-autossh
AddHost=host.containers.internal:host-gateway
Volume=%h/.ssh:/root/.ssh:ro
Exec=sh -c "apk add --no-cache autossh openssh-client && exec autossh -M 0 -N -o ServerAliveInterval=30 -o ServerAliveCountMax=3 -o ExitOnForwardFailure=yes -i /root/.ssh/id_ed25519 -p $AUTOSSH_REMOTE_PORT -R 127.0.0.1:$AUTOSSH_REMOTE_BIND_PORT:host.containers.internal:$AUTOSSH_LOCAL_PORT $AUTOSSH_REMOTE_USER@$AUTOSSH_REMOTE_HOST"
[Service]
Restart=always
[Install]
WantedBy=default.target
UNIT
log 'Autossh Quadlet generated; review host and key before enabling.'
