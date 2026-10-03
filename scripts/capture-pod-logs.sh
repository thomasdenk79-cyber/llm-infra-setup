#!/usr/bin/env bash
# Sammelt Podman- und Runtime-Logs mit Zeitstempeln fuer spaetere Auswertung.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-$root/state/logs/pods}"
mkdir -p "$out"
echo "Logsammlung aktiv: $out"
last_epoch="$(date +%s)"
while :; do
  now="$(date +%s)"
  since=$(( last_epoch > 2 ? last_epoch - 2 : last_epoch ))
  journalctl --user -u pennyroyal.service --since "@$since" --no-pager 2>/dev/null >> "$out/pennyroyal.service.log" || true
  journalctl --user -u podman-pennyroyal.service --since "@$since" --no-pager 2>/dev/null >> "$out/podman-pennyroyal.service.log" || true
  while read -r name; do
    [[ -n "$name" ]] || continue
    safe="${name//[^A-Za-z0-9_.-]/_}"
    podman logs --timestamps --since "${since}" "$name" >> "$out/${safe}.log" 2>&1 || true
  done < <(podman ps -a --format '{{.Names}}' 2>/dev/null || true)
  last_epoch="$now"
  sleep 30
done
