#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${root}/state/config-backup-$(date +%Y%m%dT%H%M%S).tar.gz}"
items=(); for item in config quadlet systemd Makefile versions.lock; do [[ -e "${root}/${item}" ]] && items+=("${item}"); done
tar --exclude='.git' --exclude='state' --exclude='*.secret' -czf "${out}" -C "${root}" "${items[@]}"
printf 'Backup written: %s\n' "${out}"
