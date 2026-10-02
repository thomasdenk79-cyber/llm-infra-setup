#!/usr/bin/env bash
set -Eeuo pipefail

# One-command setup for Qwen3.8 Flash Next + Pennyroyal.
# Edit/override these variables before running:
#   STORAGE_ROOT=/srv                 # dedicated mounted storage root
#   ZFS_POOL=zpcachyossrv             # existing pool (optional)
#   ZFS_COMPRESSION=lz4               # lz4, zstd:1..19 when pool supports zstd
#   AUTO_REBOOT=1 ./setup.sh
AUTO_REBOOT="${AUTO_REBOOT:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
START_RUNTIME="${START_RUNTIME:-1}"
API_TEST="${API_TEST:-1}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-8}"
RETRY_DELAY="${RETRY_DELAY:-10}"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
lock_file="${XDG_RUNTIME_DIR:-/tmp}/llm-infra-setup.lock"
exec 9>"${lock_file}"
flock -n 9 || { log 'Another setup run is active; wait for it to finish.'; exit 0; }
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"

export ZFS_POOL="${ZFS_POOL:-}"
export STORAGE_ROOT="${STORAGE_ROOT:-/srv}"
export MODEL_ID="${MODEL_ID:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
export PENNYROYAL_IMAGE="${PENNYROYAL_IMAGE:-ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
export PENNYROYAL_PORT="${PENNYROYAL_PORT:-8001}"

run() { log "+ $*"; "$@"; }
status_file="${root}/state/setup.status"
status() { printf '%s\t%s\n' "$(date -Is)" "$*" | tee -a "${status_file}"; }
mkdir -p "${root}/state"
status 'started'

status 'zfs'; run make zfs

if [[ "${INSTALL_PACKAGES}" == 1 ]] && ! command -v podman >/dev/null 2>&1; then
  status 'packages'; retry make install
fi

if ! nvidia-smi -L >/dev/null 2>&1; then
  status 'nvidia-driver'; retry make nvidia-driver
  log 'NVIDIA is not active in the current kernel. Reboot, then run this same setup script again.'
  if [[ "${AUTO_REBOOT}" == 1 ]]; then
    sudo systemctl reboot
  fi
  exit 0
fi

status 'podman'; retry make podman

model_job=""; image_job=""
if [[ "${DOWNLOAD_MODEL}" == 1 ]]; then
  model_dir="${LLM_MODELS_DIR:-/srv/llm/models}/$(basename "${MODEL_ID}")"
  if [[ -f "${model_dir}/config.json" ]] && ! find "${model_dir}" -path "${model_dir}/.cache" -prune -o -type f -name '*.incomplete' -print -quit | grep -q .; then
    status 'model-verify'; retry make model-verify
  else
    status 'model-download-start'; (retry make model >"${root}/state/model-download.log" 2>&1) & model_job=$!
  fi
fi

if [[ "${START_RUNTIME}" == 1 ]]; then
  status 'pennyroyal-image-start'; (retry make pennyroyal >"${root}/state/pennyroyal-install.log" 2>&1) & image_job=$!
fi

if [[ -n "${model_job}" ]]; then
  wait "${model_job}"; status 'model-verify'; retry make model-verify
fi
if [[ -n "${image_job}" ]]; then
  wait "${image_job}"
fi

if [[ "${START_RUNTIME}" == 1 ]]; then
  status 'deploy'; retry make deploy
  if [[ "${API_TEST}" == 1 ]]; then
    status 'api-wait'
    for _ in $(seq 1 180); do curl -fsS "http://127.0.0.1:${PENNYROYAL_PORT}/health" >/dev/null 2>&1 && break; sleep 5; done
    curl -fsS "http://127.0.0.1:${PENNYROYAL_PORT}/health" >/dev/null
    status 'api-test'
    curl -fsS --max-time 300 -H 'Content-Type: application/json' \
      -d '{"model":"pennyroyal","messages":[{"role":"user","content":"Reply with exactly: Pennyroyal API OK"}],"max_tokens":16,"stream":false}' \
      "http://127.0.0.1:${PENNYROYAL_PORT}/v1/chat/completions" | tee "${root}/state/api-smoke.json"
    opencode_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
    install -d -m 0755 "${opencode_dir}"
    cat > "${opencode_dir}/opencode.json" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {"local-pennyroyal": {"npm": "@ai-sdk/openai-compatible", "name": "Local Pennyroyal Qwen", "options": {"baseURL": "http://127.0.0.1:${PENNYROYAL_PORT}/v1", "apiKey": "local"}, "models": {"pennyroyal": {"name": "Qwen3.8 Flash Next (local)"}}}},
  "model": "local-pennyroyal/pennyroyal"
}
EOF
  fi
  run make healthcheck || log 'Healthcheck is not ready yet; inspect: journalctl --user -u pennyroyal.service -f'
fi

status 'complete'
log 'Qwen3.8 Flash Next + Pennyroyal setup complete.'
