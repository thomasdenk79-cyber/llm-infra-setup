#!/usr/bin/env bash
set -Eeuo pipefail
url="${SGLANG_URL:-http://127.0.0.1:${PENNYROYAL_PORT:-8001}}/health"
command -v curl >/dev/null || { echo 'curl is required' >&2; exit 1; }
printf 'Endpoint: %s\n' "$url"
curl --fail --silent --show-error --max-time 10 "$url" >/dev/null
printf 'Health endpoint reachable. Use the runtime's native benchmark client for token throughput.\n'
