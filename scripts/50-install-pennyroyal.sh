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
: "${PENNY_PLE_BACKEND:=nvme}"
: "${PENNY_PLE_NVME_MODEL:=/srv/llm/ple-nvme/Qwen3.8-Flash-Next-PLE-NVME}"
# Zero disables the host RAM HiCache tier; this is useful on 64-GB hosts
# where the model loader's temporary CPU peak leaves no reservation margin.
: "${PENNY_HICACHE_SIZE_GB:=8}"
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
Volume=${LLM_CACHE_DIR}/pennyroyal:/cache:U,Z
Volume=${LLM_NIXL_DIR}:/nixl:U,Z
Volume=$(dirname "${PENNY_PLE_NVME_MODEL}"):/ple:ro,Z
Volume=${root}/config/pennyroyal/serve-flash-next-frspec.sh:/opt/pennyroyal/configs/pennyroyal/serve-flash-next-frspec.sh:ro,Z
Environment=HF_HOME=/cache/huggingface
Environment=TARGET_MODEL=/models/Qwen3.8-Flash-Next-NVFP4
Environment=CACHE_BASE=/cache
Environment=NIXL_STORAGE_BASE=/nixl
Environment=PENNY_HICACHE_SIZE_GB=${PENNY_HICACHE_SIZE_GB}
Environment=PENNY_PLE_BACKEND=${PENNY_PLE_BACKEND}
Environment=PENNY_PLE_NVME_MODEL=/ple/$(basename "${PENNY_PLE_NVME_MODEL}")
Exec=next

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
UNIT
log "Pennyroyal image pinned to ${digest} and Quadlet unit generated."
log 'Review model path and start with: systemctl --user daemon-reload && systemctl --user enable --now pennyroyal.service'
