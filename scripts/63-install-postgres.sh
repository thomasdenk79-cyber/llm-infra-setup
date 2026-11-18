#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
lock_feld() { awk -F': ' -v f="$1" '$1==f{gsub(/ /,"",$2); print $2; exit}' "${root}/versions.lock" 2>/dev/null || true; }
: "${POSTGRES_IMAGE:=$(lock_feld postgres_image)}"
[[ -z "${POSTGRES_IMAGE}" ]] && POSTGRES_IMAGE="docker.io/library/postgres:$(lock_feld postgres)"
pg_digest="$(lock_feld postgres_image_digest)"
[[ -n "${pg_digest}" && "${POSTGRES_IMAGE}" != *"@sha256:"* ]] && POSTGRES_IMAGE="${POSTGRES_IMAGE}@${pg_digest}"
: "${POSTGRES_PORT:=5432}"
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/litellm-postgres.container" <<UNIT
# GENERIERT von scripts/63-install-postgres.sh - dort ändern, nicht hier.
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
RestartSec=15
[Install]
WantedBy=default.target
UNIT
log 'PostgreSQL Quadlet generated. Create postgres.env locally with POSTGRES_DB, POSTGRES_USER and POSTGRES_PASSWORD.'
