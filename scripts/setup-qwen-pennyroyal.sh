#!/usr/bin/env bash
set -Eeuo pipefail

# One-command setup for Qwen3.8 Flash Next + Pennyroyal.
# Override these before running, for example:
#   ZFS_POOL=zpcachyossrv AUTO_REBOOT=1 ./scripts/setup-qwen-pennyroyal.sh
AUTO_REBOOT="${AUTO_REBOOT:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
START_RUNTIME="${START_RUNTIME:-1}"
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

if [[ "${DOWNLOAD_MODEL}" == 1 ]]; then
  model_dir="${LLM_MODELS_DIR:-/srv/llm/models}/$(basename "${MODEL_ID}")"
  if [[ -f "${model_dir}/config.json" ]] && ! find "${model_dir}" -path "${model_dir}/.cache" -prune -o -type f -name '*.incomplete' -print -quit | grep -q .; then
    status 'model-verify'; retry make model-verify
  elif pgrep -af '[h]f download .*RadixArk/Qwen3.8-Flash-Next-NVFP4' >/dev/null; then
    log 'Model download is already running; continuing to runtime setup after it finishes.'
    while pgrep -af '[h]f download .*RadixArk/Qwen3.8-Flash-Next-NVFP4' >/dev/null; do sleep 15; done
    run make model-verify
  else
    status 'model-download'; retry make model
    status 'model-verify'; retry make model-verify
  fi
fi

if [[ "${START_RUNTIME}" == 1 ]]; then
  status 'pennyroyal-image'; retry make pennyroyal
  status 'deploy'; retry make deploy
  run make healthcheck || log 'Healthcheck is not ready yet; inspect: journalctl --user -u pennyroyal.service -f'
fi

status 'complete'
log 'Qwen3.8 Flash Next + Pennyroyal setup complete.'
