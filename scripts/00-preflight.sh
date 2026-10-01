#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

REPORT="${STATE_DIR}/preflight-report.txt"
mkdir -p "${STATE_DIR}"
exec > >(tee "${REPORT}") 2>&1

printf 'LLM infrastructure preflight\nGenerated: %s\nHost: %s\n' "$(date -Is)" "$(hostname)"
capture 'OS' bash -c 'cat /etc/os-release; uname -a'
capture 'CPU' lscpu
capture 'RAM' free -h
capture 'NUMA' numactl --hardware
capture 'NVIDIA driver and GPU' nvidia-smi
capture 'NVIDIA GPU UUID and details' nvidia-smi --query-gpu=name,uuid,memory.total,driver_version,compute_cap,pci.bus_id --format=csv
capture 'CUDA compatibility' nvidia-smi --query-gpu=driver_version,cuda_version --format=csv
capture 'PCIe link' bash -c 'for d in /sys/bus/pci/devices/*; do [[ -f "$d/vendor" ]] && grep -q 0x10de "$d/vendor" 2>/dev/null && { echo "$d"; cat "$d/current_link_speed" "$d/current_link_width" 2>/dev/null || true; }; done'
capture 'Podman' podman --version
capture 'crun' crun --version
capture 'systemd' systemctl --version
capture 'ZFS' zfs version
capture 'ZFS pools' zpool list -H -o name,size,alloc,free,health
capture 'ZFS datasets' zfs list -o name,mountpoint,used,avail,compression,recordsize,atime
capture 'Mounts and filesystems' findmnt -D
capture 'Disk space' df -hT
capture 'NVIDIA container toolkit' nvidia-ctk --version
capture 'NVIDIA CDI devices' nvidia-ctk cdi list
capture 'Git' git --version
capture 'Python' python --version
capture 'uv' uv --version
capture 'Listening ports' ss -lntup

printf '\nPreflight report: %s\n' "${REPORT}"
