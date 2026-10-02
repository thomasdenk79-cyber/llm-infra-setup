#!/usr/bin/env bash
set -Eeuo pipefail

# Friendly one-command entrypoint. All options are environment variables:
#   AUTO_REBOOT=1 ./setup.sh
#   DOWNLOAD_MODEL=0 ./setup.sh
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
exec "${root}/scripts/setup-qwen-pennyroyal.sh" "$@"
