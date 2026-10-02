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

opencode_bin="${HOME}/.opencode/bin/opencode"
if ! command -v opencode >/dev/null 2>&1 && [[ ! -x "${opencode_bin}" ]]; then
  command -v curl >/dev/null 2>&1 || { log 'curl missing; cannot install OpenCode'; exit 1; }
  curl -fsSL https://opencode.ai/install | bash -s -- --no-modify-path
fi

if [[ -x "${opencode_bin}" ]]; then
  # The installer intentionally does not modify shell startup files. Expose
  # the binary through the conventional per-user bin directory and add that
  # directory to login and interactive Bash sessions idempotently.
  user_bin="${HOME}/.local/bin"
  install -d -m 0755 "${user_bin}"
  ln -sfn "${opencode_bin}" "${user_bin}/opencode"
  for profile in "${HOME}/.profile" "${HOME}/.bashrc"; do
    touch "${profile}"
    grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "${profile}" ||
      printf '\n# User-installed CLI tools\nexport PATH="$HOME/.local/bin:$PATH"\n' >>"${profile}"
  done
  export PATH="${user_bin}:${PATH}"
  log "OpenCode available at ${user_bin}/opencode ($("${user_bin}/opencode" --version 2>/dev/null || true))"
fi
command -v podman-tui >/dev/null 2>&1 && log 'podman-tui available' || log 'podman-tui package unavailable; skipping.'
