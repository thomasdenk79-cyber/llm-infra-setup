#!/usr/bin/env bash
set -u
if [[ "${1:-}" == --install ]]; then
  root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
  sudo install -Dm755 "$0" /usr/local/sbin/host-power-stability.sh
  sudo install -Dm644 "$root/systemd/host-power-stability.service" /etc/systemd/system/host-power-stability.service
  sudo install -Dm644 "$root/rules/80-egpu-no-runtime-pm.rules" /etc/udev/rules.d/80-egpu-no-runtime-pm.rules
  sudo systemctl disable --now power-profiles-daemon.service 2>/dev/null || true
  sudo systemctl daemon-reload
  sudo systemctl enable --now host-power-stability.service
  sudo udevadm control --reload-rules
  sudo udevadm trigger --subsystem-match=pci
  sudo udevadm trigger --subsystem-match=thunderbolt
  sudo python3 - <<'PYGRUB'
from pathlib import Path
import re
p=Path('/etc/default/grub')
s=p.read_text()
line=next(x for x in s.splitlines() if x.startswith('GRUB_CMDLINE_LINUX_DEFAULT='))
vals=re.search(r"=['\"](.*?)['\"]\s*$", line).group(1).split()
for option in ('pcie_aspm=off', 'usbcore.autosuspend=-1', 'nvme_core.default_ps_max_latency_us=0'):
    if option not in vals:
        vals.append(option)
p.write_text(s.replace(line, "GRUB_CMDLINE_LINUX_DEFAULT='" + ' '.join(vals) + "'"))
PYGRUB
  sudo grub-mkconfig -o /boot/grub/grub.cfg >/dev/null
  exit 0
fi
# Keep PCIe/Thunderbolt and other runtime-managed devices awake on eGPU hosts.
# This is intentional for stability: it trades idle power for avoiding link/device wake failures.
set_power_control() {
  local f="$1"
  [ -w "$f" ] || return 0
  printf '%s\n' on >"$f" 2>/dev/null || true
}
for f in /sys/bus/pci/devices/*/power/control /sys/bus/thunderbolt/devices/*/power/control; do
  set_power_control "$f"
done
for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
  [ -w "$f" ] && printf '%s\n' performance >"$f" 2>/dev/null || true
done
# NVIDIA persistence avoids repeated GPU power-state transitions between clients.
command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -pm 1 >/dev/null 2>&1 || true
