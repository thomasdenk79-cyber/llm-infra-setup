#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# This is an operator-invoked action: it installs and starts the prepared user units.
"${root}/scripts/deploy.sh"
for unit in litellm pennyroyal prometheus grafana loki alloy dozzle llm-autossh komodo-periphery; do
  systemctl --user enable --now "${unit}.service" 2>/dev/null || printf 'Skipped unavailable unit: %s\n' "$unit"
done
