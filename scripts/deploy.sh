#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
unit_src="${root}/quadlet/pennyroyal.container"
[[ -f "${unit_src}" ]] || { log 'Generate quadlet first with scripts/50-install-pennyroyal.sh'; exit 1; }
user_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/containers/systemd"
install -d -m 0755 "${user_dir}"
network_src="${root}/quadlet/llm-inference.network"
[[ -f "${network_src}" ]] || { log 'Missing llm-inference.network quadlet'; exit 1; }
install -m 0644 "${network_src}" "${user_dir}/llm-inference.network"
install -m 0644 "${unit_src}" "${user_dir}/pennyroyal.container"
install -d -m 0755 "${user_dir}/default.target.wants"
ln -sfn "../llm-inference.network" "${user_dir}/default.target.wants/llm-inference.network"
ln -sfn "../pennyroyal.container" "${user_dir}/default.target.wants/pennyroyal.container"
systemctl --user daemon-reload
systemctl --user start llm-inference-network.service
systemctl --user start pennyroyal.service
log 'Pennyroyal deployed as a rootless user Quadlet service.'
