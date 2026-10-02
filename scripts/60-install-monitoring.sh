#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
user_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
install -d -m 0755 "${user_dir}"
for unit in "${root}"/quadlet/{llm-observability.network,prometheus.container,grafana.container,loki.container,alloy.container,dozzle.container}; do
  sed "s#@CONFIG_ROOT@#${root}#g" "${unit}" > "${user_dir}/$(basename "${unit}")"
done
install -d -m 0700 "${HOME}/.config/containers/systemd"
log 'Monitoring Quadlets installed. Set a Podman secret named grafana_admin_password before starting Grafana.'
