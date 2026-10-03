#!/usr/bin/env bash
# Erzeugt alle lokalen Zugangsdaten (nur wenn sie noch nicht existieren).
# Dateien liegen ausserhalb des Repos in ~/.config/llm-infra (Modus 0600).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"
ensure_base_credentials
show_credentials
