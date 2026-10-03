#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/open-webui.container" <<'UNIT'
# GENERIERT von scripts/60-install-open-webui.sh - dort ändern, nicht hier.
[Unit]
Description=Open WebUI chat and RAG interface
After=litellm.service
Wants=llm-inference-network.service

[Container]
Image=ghcr.io/open-webui/open-webui:v0.11.4
ContainerName=open-webui
Network=llm-inference.network
PublishPort=127.0.0.1:3001:8080
EnvironmentFile=%h/.config/llm-infra/open-webui.env
Volume=%h/.local/share/llm-infra/open-webui:/app/backend/data:Z,U

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
log 'Open WebUI Quadlet generated on localhost:3001.'
