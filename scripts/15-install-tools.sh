#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"

# Operator tools are optional to the inference runtime, but installed by the
# master setup so the host is manageable immediately after bootstrap.
if pacman -Si podman-tui >/dev/null 2>&1 && ! command -v podman-tui >/dev/null 2>&1; then
  retry sudo pacman -S --needed --noconfirm podman-tui
fi

systemctl --user enable --now podman.socket

if ! command -v opencode >/dev/null 2>&1 && [[ ! -x "${HOME}/.opencode/bin/opencode" ]]; then
  command -v curl >/dev/null 2>&1 || { log 'curl missing; cannot install OpenCode'; exit 1; }
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
fi

if [[ -x "${HOME}/.opencode/bin/opencode" ]]; then
  log "OpenCode available at ${HOME}/.opencode/bin/opencode"
fi
command -v podman-tui >/dev/null 2>&1 && log 'podman-tui available' || log 'podman-tui package unavailable; skipping.'
