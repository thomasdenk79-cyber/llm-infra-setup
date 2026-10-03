#!/usr/bin/env bash
# Zeigt die lokal erzeugten Zugangsdaten an.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/secrets.sh"
show_credentials
