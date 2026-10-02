#!/usr/bin/env bash
set -Eeuo pipefail

# One-command setup for Qwen3.8 Flash Next + Pennyroyal.
# Override these before running, for example:
#   ZFS_POOL=zpcachyossrv AUTO_REBOOT=1 ./scripts/setup-qwen-pennyroyal.sh
AUTO_REBOOT="${AUTO_REBOOT:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
START_RUNTIME="${START_RUNTIME:-1}"

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"

export ZFS_POOL="${ZFS_POOL:-}"
export MODEL_ID="${MODEL_ID:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
export PENNYROYAL_IMAGE="${PENNYROYAL_IMAGE:-ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
export PENNYROYAL_PORT="${PENNYROYAL_PORT:-8001}"

run() { log "+ $*"; "$@"; }

run make zfs

if [[ "${INSTALL_PACKAGES}" == 1 ]] && ! command -v podman >/dev/null 2>&1; then
  run make install
fi

if ! nvidia-smi -L >/dev/null 2>&1; then
  run make nvidia-driver
  log 'NVIDIA is not active in the current kernel. Reboot, then run this same setup script again.'
  if [[ "${AUTO_REBOOT}" == 1 ]]; then
    sudo systemctl reboot
  fi
  exit 0
fi

run make podman

if [[ "${DOWNLOAD_MODEL}" == 1 ]]; then
  model_dir="${LLM_MODELS_DIR:-/srv/llm/models}/$(basename "${MODEL_ID}")"
  if [[ -f "${model_dir}/config.json" ]] && ! find "${model_dir}" -path "${model_dir}/.cache" -prune -o -type f -name '*.incomplete' -print -quit | grep -q .; then
    run make model-verify
  elif pgrep -af '[h]f download .*RadixArk/Qwen3.8-Flash-Next-NVFP4' >/dev/null; then
    log 'Model download is already running; continuing to runtime setup after it finishes.'
    while pgrep -af '[h]f download .*RadixArk/Qwen3.8-Flash-Next-NVFP4' >/dev/null; do sleep 15; done
    run make model-verify
  else
    run make model
    run make model-verify
  fi
fi

if [[ "${START_RUNTIME}" == 1 ]]; then
  run make pennyroyal
  run make deploy
  run make healthcheck || log 'Healthcheck is not ready yet; inspect: journalctl --user -u pennyroyal.service -f'
fi

log 'Qwen3.8 Flash Next + Pennyroyal setup complete.'
