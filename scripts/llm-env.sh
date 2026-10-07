#!/usr/bin/env bash
# Export local gateway credentials for interactive agent CLIs.
set -Eeuo pipefail
gateway_env="${HOME}/.config/llm-infra/gateway.env"
if [[ ! -r "$gateway_env" ]]; then
  echo "LiteLLM credentials not found: $gateway_env (run make deploy-ready first)" >&2
  return 1 2>/dev/null || exit 1
fi
# shellcheck disable=SC1090
source "$gateway_env"
export LLM_INFRA_API_KEY="${LITELLM_MASTER_KEY:?LITELLM_MASTER_KEY missing in gateway.env}"
export LLM_INFRA_BASE_URL="${LLM_INFRA_BASE_URL:-http://127.0.0.1:4000/v1}"
