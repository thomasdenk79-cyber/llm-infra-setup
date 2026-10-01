#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
packages=(podman podman-compose buildah skopeo crun nvidia-container-toolkit git git-lfs curl wget jq yq rsync openssh autossh python uv age smartmontools shellcheck yamllint make)
missing=()
for package in "${packages[@]}"; do
  pacman -Qi "${package}" >/dev/null 2>&1 || missing+=("${package}")
done
if ((${#missing[@]})); then
  log "Installing missing packages: ${missing[*]}"
  sudo pacman -S --needed --noconfirm "${missing[@]}"
else
  log 'All required packages are already installed.'
fi
log 'Package phase complete.'
