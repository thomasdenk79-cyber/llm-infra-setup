#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
install -d -m 0755 "${root}/quadlet"
config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra/homepage"
install -d -m 0755 "${config_dir}"
cp -f "${root}"/config/homepage/*.yaml "${config_dir}/"
cat > "${root}/quadlet/homepage.container" <<'UNIT'
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
Environment=HOMEPAGE_ALLOWED_HOSTS=127.0.0.1:3002,localhost:3002
Volume=%h/.config/llm-infra/homepage:/app/config:Z,U

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
log 'Homepage portal Quadlet generated on localhost:3002.'
