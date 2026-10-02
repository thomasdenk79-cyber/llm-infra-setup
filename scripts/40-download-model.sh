#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${MODEL_ID:=RadixArk/Qwen3.8-Flash-Next-NVFP4}"
command -v huggingface-cli >/dev/null 2>&1 || { log 'huggingface-cli is missing; install huggingface_hub and authenticate separately.'; exit 1; }
mkdir -p "${LLM_MODELS_DIR}"
target="${LLM_MODELS_DIR}/$(basename "${MODEL_ID}")"
if [[ -f "${target}/config.json" ]]; then log "Model already present: ${target}"; exit 0; fi
huggingface-cli download "${MODEL_ID}" --local-dir "${target}" --local-dir-use-symlinks False
log "Model downloaded to ${target}"
