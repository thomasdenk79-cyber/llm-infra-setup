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
  python - <<'PY' | podman secret create grafana_admin_password - >/dev/null
import secrets
print(secrets.token_urlsafe(32))
PY
  log "Created rootless Podman secret ${name}."
}

ensure_postgres_env() {
  local env_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra"
  local env_file="${env_dir}/postgres.env"
  install -d -m 0700 "${env_dir}" "${HOME}/.local/share/llm-infra/postgres"
  if [[ ! -f "${env_file}" ]]; then
    local password
    password="$(python -c 'import secrets; print(secrets.token_urlsafe(32))')"
    umask 077
    cat > "${env_file}" <<EOF
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=${password}
EOF
    log "Created PostgreSQL credentials at ${env_file} (outside Git)."
  fi
}

command -v podman >/dev/null 2>&1 || { log 'podman is required'; exit 1; }
ensure_secret grafana_admin_password
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{loki,prometheus,grafana}
"${root}/scripts/63-install-postgres.sh"
ensure_postgres_env
install_unit litellm-postgres.container
for unit in llm-observability.network loki.container prometheus.container grafana.container alloy.container dozzle.container; do
  install_unit "${unit}"
done
systemctl --user daemon-reload
systemctl --user start litellm-postgres.service
systemctl --user start llm-observability-network.service
for unit in loki prometheus grafana alloy dozzle; do
  systemctl --user start "${unit}.service"
done
log 'GPU-independent observability services started.'
