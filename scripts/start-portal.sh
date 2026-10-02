#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
"${root}/scripts/60-install-homepage.sh"
user_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
install -d -m 0755 "${user_dir}/default.target.wants"
sed "s#@CONFIG_ROOT@#${root}#g" "${root}/quadlet/homepage.container" > "${user_dir}/homepage.container"
chmod 0644 "${user_dir}/homepage.container"
ln -sfn ../homepage.container "${user_dir}/default.target.wants/homepage.container"
systemctl --user daemon-reload
systemctl --user start llm-observability-network.service 2>/dev/null || true
systemctl --user start homepage.service
url="http://127.0.0.1:3002"
xdg-open "${url}" >/dev/null 2>&1 || true
echo "Portal: ${url}"
