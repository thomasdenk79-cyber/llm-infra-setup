#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
user_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
install -d -m 0755 "${user_dir}/default.target.wants"

install_unit() {
  local name="$1"
  local src="${root}/quadlet/${name}"
  [[ -f "${src}" ]] || { log "Missing generated unit: ${src}"; return 1; }
  sed "s#@CONFIG_ROOT@#${root}#g" "${src}" > "${user_dir}/${name}"
  chmod 0644 "${user_dir}/${name}"
  ln -sfn "../${name}" "${user_dir}/default.target.wants/${name}"
}

ensure_secret() {
  local name="$1"
  if podman secret inspect "${name}" >/dev/null 2>&1; then
    return 0
  fi
  printf '%s\n' 'admin' | podman secret create grafana_admin_password - >/dev/null
  log "Created rootless Podman secret ${name}."
}

ensure_postgres_env() {
  local env_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra"
  local env_file="${env_dir}/postgres.env"
  install -d -m 0700 "${env_dir}" "${HOME}/.local/share/llm-infra/postgres"
  if [[ ! -f "${env_file}" ]]; then
    umask 077
    cat > "${env_file}" <<EOF
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=llm-infra
EOF
    log "Created PostgreSQL credentials at ${env_file} (outside Git)."
  fi
}

ensure_gateway_env() {
  local env_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra" env_file="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra/gateway.env"
  [[ -f "${env_file}" ]] && return 0
  # shellcheck disable=SC1090
  source "${env_dir}/postgres.env"
  umask 077
  cat > "${env_file}" <<EOF
LITELLM_MASTER_KEY=sk-llm-infra-local
LITELLM_SALT_KEY=llm-infra-salt
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@litellm-postgres:5432/${POSTGRES_DB}
EOF
}

ensure_open_webui_env() {
  local env_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra" env_file="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra/open-webui.env"
  [[ -f "${env_file}" ]] && return 0
  # shellcheck disable=SC1090
  source "${env_dir}/gateway.env"
  umask 077
  cat > "${env_file}" <<EOF
WEBUI_SECRET_KEY=llm-infra-webui-local
ENABLE_SIGNUP=true
ENABLE_OPENAI_API=true
OPENAI_API_BASE_URL=http://litellm:4000/v1
OPENAI_API_KEY=${LITELLM_MASTER_KEY}
EOF
}

command -v podman >/dev/null 2>&1 || { log 'podman is required'; exit 1; }
ensure_secret grafana_admin_password
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{loki,prometheus,grafana,open-webui,homepage/logs}
"${root}/scripts/63-install-postgres.sh"
ensure_postgres_env
ensure_gateway_env
ensure_open_webui_env
"${root}/scripts/60-install-gateway.sh"
install_unit litellm-postgres.container
install_unit litellm.container
"${root}/scripts/60-install-open-webui.sh"
"${root}/scripts/60-install-homepage.sh"
install_unit open-webui.container
install_unit homepage.container
for unit in llm-inference.network llm-observability.network loki.container prometheus.container grafana.container alloy.container dozzle.container; do
  install_unit "${unit}"
done
systemctl --user daemon-reload
systemctl --user start llm-inference-network.service
systemctl --user restart litellm-postgres.service
systemctl --user start llm-observability-network.service
for unit in loki prometheus grafana alloy dozzle; do
  systemctl --user start "${unit}.service"
done
systemctl --user start litellm.service
systemctl --user start open-webui.service
systemctl --user start homepage.service
log 'GPU-independent services started. Chat is ready when the LLM runtime is available.'
