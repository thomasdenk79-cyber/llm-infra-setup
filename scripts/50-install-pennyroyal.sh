#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${PENNYROYAL_IMAGE:=ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
: "${PENNYROYAL_PORT:=8001}"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
command -v podman >/dev/null || { log 'podman is required'; exit 1; }
podman pull "${PENNYROYAL_IMAGE}"
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/pennyroyal.container" <<UNIT
[Unit]
Description=Pennyroyal SGLang RTX PRO 6000 runtime
After=network-online.target

[Container]
Image=${PENNYROYAL_IMAGE}
ContainerName=pennyroyal
PublishPort=${PENNYROYAL_PORT}:8001
Device=nvidia.com/gpu=all
Volume=${LLM_MODELS_DIR}:/models:ro
Environment=HF_HOME=/cache/huggingface
Exec=python3 -m sglang.launch_server --model-path /models/Qwen3.8-Flash-Next-NVFP4 --host 0.0.0.0 --port 8001 --served-model-name qwen3.8-flash-next --context-length ${MODEL_CONTEXT_LENGTH:-524288}

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
log "Pennyroyal image pinned and Quadlet unit generated."
log 'Review model path and start with: systemctl --user daemon-reload && systemctl --user enable --now pennyroyal.service'
