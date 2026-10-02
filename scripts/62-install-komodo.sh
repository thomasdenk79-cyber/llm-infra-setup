#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; source "$root/lib/common.sh"
[[ -f "$root/config/komodo.env" ]] && source "$root/config/komodo.env" || true
: "${KOMODO_IMAGE:=ghcr.io/moghtech/komodo-periphery:2.3.3}"; : "${KOMODO_SERVER_URL:=https://komodo.example.net}"; : "${KOMODO_PERIPHERY_NAME:=llm-host}"
install -d "$root/quadlet"; cat > "$root/quadlet/komodo-periphery.container" <<UNIT
[Unit]
Description=Komodo Periphery agent
After=network-online.target
[Container]
Image=$KOMODO_IMAGE
ContainerName=komodo-periphery
PublishPort=127.0.0.1:8120:8120
EnvironmentFile=%h/.config/llm-infra/komodo.env
Environment=PERIPHERY_SERVER=$KOMODO_SERVER_URL
Environment=PERIPHERY_HOST=$KOMODO_PERIPHERY_NAME
Volume=%h/.local/share/komodo:/etc/komodo:Z
[Service]
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
log 'Komodo Periphery Quadlet generated; credentials stay in local env.'
