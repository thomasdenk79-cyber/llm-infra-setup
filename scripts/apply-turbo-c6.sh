#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/common.sh"
source "$root/lib/units.sh"
unit=sglang-turbo-c6.container
[[ -f "$root/quadlet/$unit" ]] || { log 'Turbo-Unit fehlt: make turbo-c6-install'; exit 1; }
render_unit "$unit"
systemd_reload
systemctl --user enable --now sglang-turbo-c6.service
log 'Turbo-C6 gestartet. Status: systemctl --user status sglang-turbo-c6.service'
log 'Smoke-Check: curl -fsS http://127.0.0.1:8002/health'
