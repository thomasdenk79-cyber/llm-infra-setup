#!/usr/bin/env bash
# Install the llmlogs command for the current WSL user without replacing files.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
bin_dir="${HOME}/.local/bin"
target="${bin_dir}/llmlogs"
profile="${HOME}/.bashrc"

install -d -m 0755 "$bin_dir"
install -m 0755 "${root}/scripts/llmlogs.sh" "$target"
for profile in "${HOME}/.profile" "${HOME}/.bashrc"; do
  touch "$profile"
  grep -Fqx 'export PATH="$HOME/.local/bin:$PATH"' "$profile" ||
    printf '\n# User-installed CLI tools\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$profile"
done

echo "Installed: $target"
echo 'Open a new WSL shell or run: source ~/.bashrc'
echo 'Usage: llmlogs [--help]'
