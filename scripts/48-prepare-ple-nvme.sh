#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${LLM_MODELS_DIR:=${HOME}/models}"
: "${PENNYROYAL_IMAGE:=ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
: "${PENNY_PLE_NVME_MODEL:=${HOME}/.local/share/llm-infra/ple/Qwen3.8-Flash-Next-PLE-NVME}"
source_dir="${LLM_MODELS_DIR}/Qwen3.8-Flash-Next-NVFP4"
parent_dir="$(dirname -- "${PENNY_PLE_NVME_MODEL}")"
command -v podman >/dev/null || { log 'podman is required'; exit 1; }
[[ -d "${source_dir}" ]] || { log "model source missing: ${source_dir}"; exit 1; }
if [[ -f "${PENNY_PLE_NVME_MODEL}/model-plefp8-00009.safetensors" && -f "${PENNY_PLE_NVME_MODEL}/model.safetensors.index.json" ]]; then
  log "NVMe PLE overlay already prepared: ${PENNY_PLE_NVME_MODEL}"
  exit 0
fi
install -d -m 0755 "${parent_dir}"
tmp_name=".$(basename -- "${PENNY_PLE_NVME_MODEL}").tmp.$$"
tmp_path="${parent_dir}/${tmp_name}"
trap 'rmdir "${tmp_path}" 2>/dev/null || true' EXIT
[[ ! -e "${tmp_path}" ]] || { log "temporary PLE path already exists: ${tmp_path}"; exit 1; }
retry podman run --rm --user 0:0 --entrypoint /opt/pennyroyal/.venv/bin/python \
  -v "${LLM_MODELS_DIR}:/models:ro" \
  -v "${parent_dir}:/ple:Z" \
  "${PENNYROYAL_IMAGE}" \
  /opt/pennyroyal/scripts/pennyroyal/prepare_ple_nvme.py \
  --source /models/Qwen3.8-Flash-Next-NVFP4 \
  --output "/ple/${tmp_name}"
podman unshare chmod 0755 "${tmp_path}"
[[ -f "${tmp_path}/model-plefp8-00009.safetensors" && -f "${tmp_path}/model.safetensors.index.json" ]] || {
  log "PLE preparer did not create the expected table/index"; exit 1;
}
mv --no-clobber "${tmp_path}" "${PENNY_PLE_NVME_MODEL}"
log "NVMe PLE overlay ready: ${PENNY_PLE_NVME_MODEL}"
