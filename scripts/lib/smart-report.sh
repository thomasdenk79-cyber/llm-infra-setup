#!/usr/bin/env bash
# Kompakte SMART-Zusammenfassung fuer Preflight und Diagnose.
# Ohne sudo-Rechte liefert das Skript einen Hinweis statt einer Fehlermeldung.
set -uo pipefail
have() { command -v "$1" >/dev/null 2>&1; }
have smartctl || { echo 'smartctl nicht installiert (pacman -S smartmontools)'; exit 0; }
for dev in /dev/nvme[0-9] /dev/sd[a-z]; do
  [[ -e "${dev}" ]] || continue
  json="$(sudo -n smartctl --json=c -a "${dev}" 2>/dev/null)"
  if [[ -z "${json}" ]]; then
    printf '%s: keine Messwerte ohne Passwortabfrage (sudo smartctl %s)\n' "${dev}" "${dev}"
    continue
  fi
  SMART_DEV="${dev}" SMART_JSON="${json}" python3 - <<'PY'
import json, os
data = json.loads(os.environ['SMART_JSON'])
dev = os.environ['SMART_DEV']
a = data.get('abstract', {})
nv = data.get('nvme_smart_health_information_log') or {}
def fmt(v, scale=1):
    return 'unbekannt' if v is None else f'{v * scale:g}'
print(f'{dev}: '
      f'zustand={"ok" if data.get("smart_status", {}).get("passed") else "NICHT OK"} '
      f'temperatur={fmt(a.get("temp", {}).get("current"))} C '
      f'abgenutzt={fmt(a.get("percentage_used") or nv.get("percentage_used"))} % '
      f'reserve={fmt(nv.get("available_spare"), 1)} % '
      f'medienfehler={fmt(nv.get("media_errors"))} '
      f'unsauber ausgestiegen={fmt(nv.get("unsafe_shutdowns"))} '
      f'geschrieben={fmt((nv.get("data_units_written") or 0) * 1000000 / 1e12)} TB '
      f'gelesen={fmt((nv.get("data_units_read") or 0) * 1000000 / 1e12)} TB '
      f'kritische Warnung={fmt(nv.get("critical_warning"))}')
PY
done
