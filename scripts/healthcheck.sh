#!/usr/bin/env bash
set -Eeuo pipefail
port="${PENNYROYAL_PORT:-8001}"
url="http://127.0.0.1:${port}/health"
if curl --fail --silent --show-error --max-time 5 "${url}"; then printf '\n'; else echo "Pennyroyal health check failed: ${url}" >&2; exit 1; fi
