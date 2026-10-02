#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${PENNYROYAL_IMAGE:=ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
: "${PENNYROYAL_PORT:=8001}"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${LLM_CACHE_DIR:=/srv/llm/cache}"
: "${LLM_NIXL_DIR:=/srv/llm/nixl}"
command -v podman >/dev/null || { log 'podman is required'; exit 1; }
retry podman pull "${PENNYROYAL_IMAGE}"
digest="$(podman image inspect "${PENNYROYAL_IMAGE}" --format '{{.Digest}}')"
[[ "${digest}" == sha256:* ]] || { log "Could not determine image digest for ${PENNYROYAL_IMAGE}"; exit 1; }
if [[ "${PENNYROYAL_IMAGE}" == *@* ]]; then
  image_ref="${PENNYROYAL_IMAGE}"
else
  image_ref="${PENNYROYAL_IMAGE}@${digest}"
fi
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/pennyroyal.container" <<UNIT
[Unit]
Description=Pennyroyal SGLang RTX PRO 6000 runtime
After=network-online.target
Wants=llm-inference-network.service

[Container]
Image=${image_ref}
ContainerName=pennyroyal
Network=llm-inference.network
PublishPort=127.0.0.1:${PENNYROYAL_PORT}:8001
AddDevice=nvidia.com/gpu=all
Volume=${LLM_MODELS_DIR}:/models:ro
Volume=${LLM_CACHE_DIR}/pennyroyal:/cache:Z
Volume=${LLM_NIXL_DIR}:/nixl:Z
Environment=HF_HOME=/cache/huggingface
Exec=python3 -m sglang.launch_server --model-path /models/Qwen3.8-Flash-Next-NVFP4 --host 0.0.0.0 --port 8001 --served-model-name qwen3.8-flash-next --context-length ${MODEL_CONTEXT_LENGTH:-524288}

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
log "Pennyroyal image pinned to ${digest} and Quadlet unit generated."
log 'Review model path and start with: systemctl --user daemon-reload && systemctl --user enable --now pennyroyal.service'
