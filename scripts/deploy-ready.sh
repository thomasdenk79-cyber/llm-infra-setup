#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
user_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"

command -v nvidia-smi >/dev/null 2>&1 || { log 'NVIDIA tools unavailable; reconnect the GPU and reboot first.'; exit 1; }
nvidia-smi -L >/dev/null 2>&1 || { log 'NVIDIA driver is not reachable; reconnect the GPU and reboot first.'; exit 1; }
nvidia-ctk cdi list >/dev/null 2>&1 || { log 'NVIDIA CDI is unavailable; run make podman after the GPU is visible.'; exit 1; }
"${root}/scripts/42-verify-model.sh"
"${root}/scripts/50-install-pennyroyal.sh"
"${root}/scripts/63-install-postgres.sh"
"${root}/scripts/60-install-gateway.sh"
"${root}/scripts/60-install-monitoring.sh"
"${root}/scripts/60-install-open-webui.sh"
"${root}/scripts/60-install-homepage.sh"

env_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/llm-infra"
install -d -m 0700 "${env_dir}" "${HOME}/.local/share/llm-infra/postgres" "${HOME}/.local/share/llm-infra/open-webui" "${HOME}/.local/share/llm-infra/homepage/logs"
postgres_env="${env_dir}/postgres.env"
if [[ ! -f "${postgres_env}" ]]; then
  umask 077
  cat > "${postgres_env}" <<EOF
POSTGRES_DB=litellm
POSTGRES_USER=litellm
POSTGRES_PASSWORD=llm-infra
EOF
fi
if [[ ! -f "${env_dir}/gateway.env" ]]; then
  # shellcheck disable=SC1090
  source "${postgres_env}"
  master="sk-llm-infra-local"
  salt="llm-infra-salt"
  umask 077
  cat > "${env_dir}/gateway.env" <<EOF
LITELLM_MASTER_KEY=${master}
LITELLM_SALT_KEY=${salt}
DATABASE_URL=postgresql://${POSTGRES_USER}:${POSTGRES_PASSWORD}@litellm-postgres:5432/${POSTGRES_DB}
EOF
fi
if [[ ! -f "${env_dir}/open-webui.env" ]]; then
  # shellcheck disable=SC1090
  source "${env_dir}/gateway.env"
  umask 077
  cat > "${env_dir}/open-webui.env" <<EOF
WEBUI_SECRET_KEY=llm-infra-webui-local
ENABLE_SIGNUP=true
ENABLE_OPENAI_API=true
OPENAI_API_BASE_URL=http://litellm:4000/v1
OPENAI_API_KEY=${LITELLM_MASTER_KEY}
EOF
fi

install -d -m 0755 "${user_dir}/default.target.wants"
install_unit() {
  local name="$1"
  sed "s#@CONFIG_ROOT@#${root}#g" "${root}/quadlet/${name}" > "${user_dir}/${name}"
  chmod 0644 "${user_dir}/${name}"
  ln -sfn "../${name}" "${user_dir}/default.target.wants/${name}"
}
for unit in llm-inference.network llm-observability.network litellm-postgres.container pennyroyal.container litellm.container open-webui.container homepage.container prometheus.container grafana.container loki.container alloy.container dozzle.container; do
  install_unit "${unit}"
done

systemctl --user daemon-reload
systemctl --user start llm-inference-network.service
systemctl --user restart litellm-postgres.service
systemctl --user start pennyroyal.service
systemctl --user start llm-observability-network.service
for unit in loki prometheus grafana alloy dozzle; do systemctl --user start "${unit}.service"; done
systemctl --user start litellm.service
systemctl --user start open-webui.service
systemctl --user start homepage.service
log 'Full GPU-backed stack started. Run make healthcheck after model loading completes.'
