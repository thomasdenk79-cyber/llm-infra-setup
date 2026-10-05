#!/usr/bin/env bash
# Creates one LiteLLM virtual key per named team member and stores it privately.
set -Eeuo pipefail
umask 077
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${SECRETS_DIR}/gateway.env"

: "${LITELLM_MASTER_KEY:?FEHLT: LITELLM_MASTER_KEY in gateway.env}"
need_cmd curl 'Jetzt ausführen: make install'
need_cmd jq 'Jetzt ausführen: make install'

gateway_url="${LITELLM_ADMIN_URL:-http://127.0.0.1:4000}"
token_dir="${SECRETS_DIR}/team-api-tokens"
install -d -m 0700 "${token_dir}"

for member in owner thomas martin johannes holger; do
  token_file="${token_dir}/${member}.key"
  if [[ -s "${token_file}" ]]; then
    log "existing token kept: ${token_file}"
    continue
  fi

  payload="$(jq -n --arg alias "team-${member}" \
    '{models:["qwen3.8-flash-next"], key_alias:$alias}')"
  response="$(curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer ${LITELLM_MASTER_KEY}" \
    -H 'Content-Type: application/json' \
    --data-binary "${payload}" \
    "${gateway_url%/}/key/generate")"
  token="$(jq -er '.key | select(type == "string" and length > 0)' <<<"${response}")"

  tmp_file="$(mktemp "${token_dir}/.${member}.XXXXXX")"
  printf '%s\n' "${token}" > "${tmp_file}"
  chmod 0600 "${tmp_file}"
  mv -n "${tmp_file}" "${token_file}"
  chmod 0600 "${token_file}"
  log "created token for ${member}: ${token_file}"
done

log 'Share each token file with its named owner through a private channel; never commit these files.'
