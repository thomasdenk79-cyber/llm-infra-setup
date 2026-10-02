#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${MODEL_ID:=RadixArk/Qwen3.8-Flash-Next-NVFP4}"
if command -v hf >/dev/null 2>&1; then hf_cmd=(hf download); hf_opts=(); elif command -v huggingface-cli >/dev/null 2>&1; then hf_cmd=(huggingface-cli download); hf_opts=(--local-dir-use-symlinks False); else log 'hf CLI is missing; install huggingface_hub and authenticate separately.'; exit 1; fi
sudo install -d -m 0755 "${LLM_MODELS_DIR}"
target="${LLM_MODELS_DIR}/$(basename "${MODEL_ID}")"
if [[ ! -d "${target}" ]]; then sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "${target}"; fi
if [[ -f "${target}/config.json" ]] && ! find "${target}" -type f -name "*.incomplete" -print -quit | grep -q .; then log "Model already present: ${target}"; exit 0; fi
if find "${target}" -type f -name "*.incomplete" -print -quit | grep -q .; then log "Resuming incomplete model download: ${target}"; fi
retry "${hf_cmd[@]}" "${MODEL_ID}" --local-dir "${target}" "${hf_opts[@]}"
log "Model downloaded to ${target}"
