#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${MODEL_ID:=RadixArk/Qwen3.8-Flash-Next-NVFP4}"
target="${LLM_MODELS_DIR}/$(basename "${MODEL_ID}")"
[[ -f "${target}/config.json" ]] || { log "Missing config.json in ${target}"; exit 1; }
if find "${target}" -type f -name '*.incomplete' -print -quit | grep -q .; then log 'Incomplete Hugging Face files remain'; exit 1; fi
count=$(find "${target}" -type f \( -name '*.safetensors' -o -name '*.safetensors.index.json' \) | wc -l)
((count > 0)) || { log 'No safetensors files found'; exit 1; }
size=$(du -sh "${target}" | awk '{print $1}')
revision=$(find "${target}/.cache/huggingface" -type f -name '*.metadata' -print -quit 2>/dev/null || true)
printf 'model_id=%s\npath=%s\nsize=%s\nsafetensor_files=%s\nmetadata=%s\n' "$MODEL_ID" "$target" "$size" "$count" "${revision:-unavailable}"
