#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
command -v podman >/dev/null 2>&1 || { log 'podman is not installed; run scripts/10-install-packages.sh first.'; exit 1; }
systemctl --user enable --now podman.socket
sudo loginctl enable-linger "${USER}" || log 'Could not enable linger; continuing.'
if command -v nvidia-ctk >/dev/null 2>&1 && command -v nvidia-smi >/dev/null 2>&1; then
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  nvidia-ctk cdi list
else
  log 'NVIDIA driver/tools are unavailable; NVIDIA CDI generation deferred.'
fi
podman info --format '{{.Host.OCIRuntime.Name}}' || true
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-ctk cdi list >/dev/null 2>&1; then
  podman run --rm --device nvidia.com/gpu=all docker.io/nvidia/cuda:12.8.1-base-ubuntu24.04 nvidia-smi
else
  log 'GPU test deferred because host NVIDIA tools or CDI are unavailable.'
fi
