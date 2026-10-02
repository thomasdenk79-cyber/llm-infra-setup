#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"

if ! lspci -nn | grep -qi 'NVIDIA.*\[10de:'; then
  log 'No NVIDIA PCI device detected; refusing to install a driver blindly.'
  exit 1
fi
if [[ ! -d "/usr/lib/modules/$(uname -r)/build" ]]; then
  log "Kernel headers for $(uname -r) are missing. Install matching CachyOS headers first."
  exit 1
fi
if ! pacman -Q linux-cachyos-headers >/dev/null 2>&1; then
  log 'The running CachyOS kernel header package is not installed.'
  exit 1
fi

# RTX PRO 6000 Blackwell (GB202) supports NVIDIA's open kernel modules. CachyOS
# may provide a kernel-matched module package already; that conflicts with the
# DKMS variant, so keep the existing packaged module when present.
if pacman -Q linux-cachyos-nvidia-open >/dev/null 2>&1; then
  log 'Using the installed linux-cachyos-nvidia-open kernel module package.'
  sudo pacman -S --needed --noconfirm nvidia-utils nvidia-settings
else
  sudo pacman -S --needed --noconfirm dkms nvidia-open-dkms nvidia-utils nvidia-settings
fi
sudo install -d -m 0755 /etc/modules-load.d
sudo install -m 0644 "${root}/config/nvidia/modules-load.conf" /etc/modules-load.d/llm-infra-nvidia.conf
sudo install -d -m 0755 /etc/modprobe.d
sudo install -m 0644 "${root}/config/nvidia/blacklist-nouveau.conf" /etc/modprobe.d/llm-infra-blacklist-nouveau.conf
sudo depmod -a "$(uname -r)"
sudo mkinitcpio -P
log 'Driver installed and initramfs rebuilt. A reboot is required before validating nvidia-smi.'
