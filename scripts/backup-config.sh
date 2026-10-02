#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
out="${1:-${root}/state/config-backup-$(date +%Y%m%dT%H%M%S).tar.gz}"
tar --exclude='.git' --exclude='state' --exclude='*.secret' -czf "${out}" -C "${root}" config quadlet systemd Makefile versions.lock
printf 'Backup written: %s\n' "${out}"
