#!/usr/bin/env bash
# GitOps-Zeitsteuerung ein- oder ausschalten. Standard ist AUS, damit niemand
# ungewollt im Hintergrund Dateien tauscht.
#
#   ./scripts/install-gitops-timer.sh enable
#   ./scripts/install-gitops-timer.sh disable
#   ./scripts/install-gitops-timer.sh status
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
action="${1:-status}"
user_dir="${HOME}/.config/systemd/user"
case "${action}" in
  enable)
    install_systemd_units "${user_dir}" llm-infra-deploy.service llm-infra-gitops.timer
    systemd_reload
    systemctl --user enable --now llm-infra-gitops.timer
    echo 'GitOps laeuft alle 6 Stunden (nur committeter Stand, kein Runtime-Neustart).'
    echo 'Pruefen: systemctl --user list-timers llm-infra-gitops.timer'
    ;;
  disable)
    systemctl --user disable --now llm-infra-gitops.timer 2>/dev/null || true
    rm -f "${user_dir}/llm-infra-gitops.timer" "${user_dir}/llm-infra-deploy.service"
    systemd_reload
    echo 'GitOps ist aus.'
    ;;
  status)
    systemctl --user list-timers --all --no-pager 'llm-infra-gitops*' 2>/dev/null || echo 'Timer nicht installiert.'
    ;;
  *) echo 'usage: install-gitops-timer.sh [enable|disable|status]' >&2; exit 2 ;;
esac
