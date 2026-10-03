#!/usr/bin/env bash
# Veraltet: bitte ./scripts/backup.sh verwenden. Das Skript bleibt als Alias
# erhalten, weil es in alten Anleitungen und Chronik-Eintraegen vorkommt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
echo 'Hinweis: backup-config.sh ist ersetzt durch scripts/backup.sh (mehr Inhalt, Pruefsummen, ZFS-Snapshot).' >&2
exec "${root}/scripts/backup.sh" "$@"
