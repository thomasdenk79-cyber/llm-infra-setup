#!/usr/bin/env bash
# Minimalpfad: nur die GPU-Runtime als rootless User-Unit starten.
# Fuer den vollstaendigen Stack (Gateway, Portal, Beobachtung) make deploy-ready
# bzw. ohne GPU make deploy-non-gpu verwenden.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
if [[ ! -f "${root}/quadlet/pennyroyal.container" ]]; then
  log 'Runtime-Unit fehlt noch; wird jetzt erzeugt.'
  run "${root}/scripts/50-install-pennyroyal.sh"
fi
install -d -m 0755 "${HOME}/.local/share/llm-infra"
install_units llm-inference.network pennyroyal.container
systemd_reload
start_units llm-inference.network pennyroyal.container
cat <<NEXT
Pennyroyal-Unit ist installiert und aktiv.
Kalter Start dauert etwa 15 Minuten. Fortschritt:
  journalctl --user -u pennyroyal.service -f
Wenn "ready to roll" im Log steht:
  make healthcheck
NEXT
