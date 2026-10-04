#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
mkdir -p "$unit_dir"
cat > "$unit_dir/llm-agent-context-watchdog.service" <<UNIT
[Unit]
Description=LLM agent context and KV pressure watchdog
After=sglang-turbo-c6.service

[Service]
Type=oneshot
ExecStart=$root/scripts/agent-context-watchdog.sh
UNIT
cat > "$unit_dir/llm-agent-context-watchdog.timer" <<UNIT
[Unit]
Description=Poll LLM agent context pressure

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
Unit=llm-agent-context-watchdog.service

[Install]
WantedBy=timers.target
UNIT
systemctl --user daemon-reload
systemctl --user enable --now llm-agent-context-watchdog.timer
printf 'Watchdog aktiv. Status: systemctl --user status llm-agent-context-watchdog.timer\n'
