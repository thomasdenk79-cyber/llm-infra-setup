#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
: "${POSTGRES_IMAGE:=docker.io/library/postgres:16.4}"
: "${POSTGRES_PORT:=5432}"
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/litellm-postgres.container" <<UNIT
[Unit]
Description=PostgreSQL for LiteLLM virtual keys
Wants=llm-inference-network.service
[Container]
Image=${POSTGRES_IMAGE}
ContainerName=litellm-postgres
Network=llm-inference.network
PublishPort=127.0.0.1:${POSTGRES_PORT}:5432
EnvironmentFile=%h/.config/llm-infra/postgres.env
Volume=%h/.local/share/llm-infra/postgres:/var/lib/postgresql/data:Z,U
[Service]
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
log 'PostgreSQL Quadlet generated. Create postgres.env locally with POSTGRES_DB, POSTGRES_USER and POSTGRES_PASSWORD.'
