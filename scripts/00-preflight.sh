#!/usr/bin/env bash
# Read-only Bestandsaufnahme des Hosts. Aendert nichts.
#
#   ./scripts/00-preflight.sh
#
# Ergebnisse:
#   state/preflight-report.txt   ausfuehrlicher Bericht
#   state/host-facts.txt         Kurzfassung fuer Vergleiche nach einem Umbau
set -Eeuo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

REPORT="${STATE_DIR}/preflight-report.txt"
FACTS="${STATE_DIR}/host-facts.txt"
mkdir -p "${STATE_DIR}"
exec > >(tee "${REPORT}") 2>&1

printf 'LLM infrastructure preflight\nGenerated: %s\nHost: %s\n' "$(date -Is)" "$(hostname)"
capture 'OS' bash -c 'cat /etc/os-release; uname -a'
capture 'Hardware' bash -c 'cat /sys/class/dmi/sys_vendor /sys/class/dmi/product_name 2>/dev/null'
capture 'CPU' lscpu
capture 'RAM' free -h
capture 'Druck (PSI)' bash -c 'for f in /proc/pressure/*; do printf "%s: " "$f"; cat "$f"; done'
capture 'NUMA' numactl --hardware
capture 'NVIDIA driver and GPU' nvidia-smi
capture 'NVIDIA GPU details' nvidia-smi --query-gpu=name,uuid,memory.total,driver_version,cuda_version,compute_cap,pci.bus_id,clocks.max.sm,power.limit --format=csv
capture 'GPU thermal and power' nvidia-smi --query-gpu=temperature.gpu,temperature.memory,clocks_event_reasons.active,power.draw,clocks.sm --format=csv
capture 'PCIe link (NVIDIA)' bash -c 'for d in /sys/bus/pci/devices/*; do [[ -f "$d/vendor" ]] && grep -q 0x10de "$d/vendor" 2>/dev/null && { echo "$d"; printf "  current: %s x%s (max: %s x%s)\n" "$(cat "$d/current_link_speed")" "$(cat "$d/current_link_width")" "$(cat "$d/max_link_speed")" "$(cat "$d/max_link_width")"; }; done'
capture 'PCIe tunneled (Thunderbolt/USB4)' bash -c 'lspci -nn 2>/dev/null | grep -iE "thunderbolt|usb4" || echo none'
capture 'Podman' podman --version
capture 'crun' crun --version
capture 'systemd' systemctl --version
capture 'ZFS' zfs version
capture 'ZFS pools' zpool list -H -o name,size,alloc,free,health
capture 'ZFS datasets' zfs list -o name,mountpoint,used,avail,compression,recordsize,atime,primarycache
capture 'ZFS ARC Grenzen' bash -c 'cat /sys/module/zfs/parameters/zfs_arc_max 2>/dev/null; cat /etc/modprobe.d/llm-infra-zfs-arc.conf 2>/dev/null'
capture 'Mounts and filesystems' findmnt -D
capture 'Disk space' df -hT
capture 'Loop devices' bash -c 'losetup -a 2>/dev/null || echo none'
capture 'fstab persistence' bash -c 'grep -E "llm-ple|ple-ext4|ple-nvme" /etc/fstab || echo "kein PLE-Eintrag in /etc/fstab (nach einem Neustart fehlt der Speicher!)"'
capture 'NVMe SMART' "${SCRIPT_DIR}/lib/smart-report.sh"
capture 'NVIDIA container toolkit' nvidia-ctk --version
capture 'NVIDIA CDI devices' nvidia-ctk cdi list
capture 'CDI alter' bash -c 'for f in /etc/cdi/*.yaml; do [[ -e "$f" ]] && printf "%s: %s\n" "$f" "$(stat -c %y "$f")"; done'
capture 'Git' git --version
capture 'Python' python --version
capture 'uv' uv --version
capture 'Container images' bash -c 'podman images --format "{{.Repository}}:{{.Tag}} {{.Size}}" 2>/dev/null || true'
capture 'User units' bash -c 'systemctl --user list-unit-files --no-pager 2>/dev/null | grep -E "pennyroyal|litellm|prometheus|grafana|loki|alloy|dozzle|homepage|open-webui|llm-|exporter" || echo keine'
capture 'Listening ports' ss -lntup
capture 'Firewall' bash -c 'systemctl is-active firewalld 2>/dev/null; nft list ruleset 2>/dev/null | head -40 || echo "nft nicht verfuegbar"'

{
  printf 'Preflight Kurzfassung %s\n' "$(date -Is)"
  printf 'host=%s kernel=%s\n' "$(hostname)" "$(uname -r)"
  printf 'gpu=%s\n' "$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)"
  printf 'gpu_uuid=%s\n' "$(nvidia-smi --query-gpu=uuid --format=csv,noheader 2>/dev/null | head -1)"
  printf 'pcie=%s\n' "$(for d in /sys/bus/pci/devices/*; do [[ -f "$d/vendor" ]] && grep -q 0x10de "$d/vendor" 2>/dev/null && printf '%s=%sx%s\n' "$(basename "$d")" "$(cat "$d/current_link_speed" 2>/dev/null)" "$(cat "$d/current_link_width" 2>/dev/null)"; done | tr '\n' ' ')"
  printf 'ram_total=%s ram_avail=%s\n' "$(awk '/MemTotal/ {print $2}' /proc/meminfo)" "$(awk '/MemAvailable/ {print $2}' /proc/meminfo)"
  printf 'zfs_pools=%s\n' "$(zpool list -H -o name,health 2>/dev/null | tr '\n' ' ')"
  printf 'podman=%s cdi=%s\n' "$(podman --version 2>/dev/null)" "$(ls /etc/cdi 2>/dev/null | tr '\n' ' ')"
  printf 'ple_mount=%s\n' "$(findmnt -n -o SOURCE,FSTYPE -T /srv/llm/ple-ext4 2>/dev/null | tr '\n' ' ')"
  printf 'fstab_ple=%s\n' "$(grep -c 'llm-ple\|ple-ext4\|ple-nvme' /etc/fstab 2>/dev/null || echo 0)"
  printf 'services=%s\n' "$(systemctl --user is-active pennyroyal.service litellm.service prometheus.service grafana.service 2>/dev/null | tr '\n' ' ')"
} > "${FACTS}" 2>/dev/null

printf '\nPreflight report: %s\n' "${REPORT}"
printf 'Preflight facts:  %s\n' "${FACTS}"
