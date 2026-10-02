#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
[[ -f "$root/config/model.env" ]] && source "$root/config/model.env"
[[ -f "$root/config/gateway.env" ]] && source "$root/config/gateway.env"
: "${LITELLM_IMAGE:=ghcr.io/berriai/litellm:v1.101.0}"; : "${LITELLM_PORT:=4000}"; : "${PENNYROYAL_BASE_URL:=http://127.0.0.1:8001/v1}"
install -d "$root/quadlet"
cat > "$root/quadlet/litellm.container" <<UNIT
[Unit]
Description=LiteLLM API gateway
After=pennyroyal.service
[Container]
Image=$LITELLM_IMAGE
ContainerName=litellm
PublishPort=127.0.0.1:$LITELLM_PORT:4000
EnvironmentFile=%h/.config/llm-infra/gateway.env
Environment=LITELLM_CONFIG=/etc/litellm/config.yaml
Volume=@CONFIG_ROOT@/config/litellm.yaml:/etc/litellm/config.yaml:ro
Exec=--config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0
[Service]
Restart=on-failure
[Install]
WantedBy=default.target
UNIT
install -d "$root/config"; cat > "$root/config/litellm.yaml" <<YAML
model_list:
  - model_name: qwen3.8-flash-next
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: ${PENNYROYAL_BASE_URL}
      api_key: "os.environ/LITELLM_MASTER_KEY"
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
YAML
log 'LiteLLM Quadlet and config generated.'
