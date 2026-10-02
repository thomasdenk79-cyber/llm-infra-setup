#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
target=/etc/environment.d/90-kwin-egpu.conf
product="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
if [[ "$product" != "20X4S3C514" && "$product" != "20X4" ]]; then
  echo "KWin eGPU override is only for ThinkPad L15 Gen 2 (20X4); found '$product'." >&2
  exit 1
fi
sudo install -d -m 0755 /etc/environment.d
sudo install -m 0644 "$root/config/kde/90-kwin-egpu.conf" "$target"
echo "Installed $target. Log out and back in to restart KWin with the override."
