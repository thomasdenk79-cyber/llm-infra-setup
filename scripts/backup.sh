#!/usr/bin/env bash
# Sichert alles, was man zum Wiederherstellen braucht - ohne Modellmassen zu kopieren.
#
#   ./scripts/backup.sh                 Backup in state/backups/
#   ./scripts/backup.sh /pfad/ziel      anderes Zielverzeichnis
#   ./scripts/restore.sh --list         vorhandene Backups zeigen
#
# Inhalt:
#   * Konfiguration aus dem Repo (config/, quadlet/, systemd/, containers/, Makefile, versions.lock)
#   * Datenbank-Inhalt von LiteLLM (pg_dump)
#   * Zustand der Dienste, Image-Digests, OpenCode-Vorschlag
#   * ZFS-Snapshot auf dem Modell-Dataset (nur Referenz, kopiert keine Daten)
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
dest_base="${1:-${root}/state/backups}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${dest_base}/${ts}"
install -d -m 0700 "${dest}"

items=(); for item in config quadlet systemd containers docs Makefile versions.lock mkdocs.yml AGENTS.md README.md; do
  [[ -e "${root}/${item}" ]] && items+=("${item}")
done
tar --exclude='config/*.env' --exclude='config/homepage/.secret.env' -czf "${dest}/repository-config.tar.gz" -C "${root}" "${items[@]}"
log 'Konfiguration gespeichert.'

if command -v podman >/dev/null 2>&1 && \
   [[ "$(podman ps --format '{{.Names}}' 2>/dev/null || true)" == *litellm-postgres* ]]; then
  # shellcheck disable=SC1090
  source "${SECRETS_DIR}/postgres.env" 2>/dev/null || { POSTGRES_DB=litellm; POSTGRES_USER=litellm; }
  podman exec litellm-postgres pg_dump -U "${POSTGRES_USER:-litellm}" -d "${POSTGRES_DB:-litellm}" \
    > "${dest}/litellm-postgres.sql" 2>"${dest}/pg_dump.err" || {
      log 'WARNUNG: pg_dump fehlgeschlagen (Datenbank laeuft nicht?); Details in pg_dump.err'; rm -f "${dest}/pg_dump.err"; }
  [[ -s "${dest}/litellm-postgres.sql" ]] && log 'Datenbank gespeichert.'
else
  log 'Datenbank-Container laeuft nicht; kein Datenbankteil im Backup.'
fi

for dir in open-webui grafana homepage; do
  src="${HOME}/.local/share/llm-infra/${dir}"
  [[ -d "${src}" ]] && tar -czf "${dest}/state-${dir}.tar.gz" -C "$(dirname "${src}")" "$(basename "${src}")" && log "Zustand ${dir} gespeichert."
done
[[ -f "${HOME}/.config/opencode/opencode.json" ]] && cp "${HOME}/.config/opencode/opencode.json" "${dest}/opencode.json"
command -v podman >/dev/null 2>&1 && podman ps -a --format '{{.Names}}|{{.Image}}|{{.Status}}' > "${dest}/containers.txt" 2>/dev/null || true
systemctl --user list-units --no-pager 'pennyroyal*' 'litellm*' 'grafana*' 'prometheus*' 'loki*' 'alloy*' 'dozzle*' 'homepage*' 'open-webui*' 'llm-*' > "${dest}/services.txt" 2>/dev/null || true

if command -v zfs >/dev/null 2>&1; then
  dataset="$(zfs list -H -o name,mountpoint 2>/dev/null | awk '$2 == "'"${LLM_MODELS_DIR:-/srv/llm/models}"'" {print $1; exit}')"
  if [[ -n "${dataset}" ]]; then
    snap="${dataset}@llm-infra-${ts}"
    if zfs list -H -o name "${snap}" >/dev/null 2>&1; then
      log "Snapshot existiert bereits: ${snap}"
    elif zfs snapshot "${snap}" 2>/dev/null; then
      log "ZFS-Snapshot angelegt: ${snap}"
      printf '%s\n' "${snap}" > "${dest}/zfs-snapshot.txt"
    else
      log 'ZFS-Snapshot nicht moeglich (Berechtigungen).'
    fi
  fi
fi

python3 - "${dest}" "${root}" <<'PY'
import hashlib, json, pathlib, subprocess, sys, datetime
dest, root = map(pathlib.Path, sys.argv[1:3])
files = {str(p.relative_to(dest)): hashlib.sha256(p.read_bytes()).hexdigest()
         for p in sorted(dest.rglob('*')) if p.is_file()}
digest = {}
try:
    out = subprocess.run(['podman', 'image', 'inspect',
                          'ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3', '--format', '{{.Digest}}'],
                         capture_output=True, text=True, timeout=30).stdout.strip()
    if out:
        digest['pennyroyal_image_digest'] = out
except Exception:
    pass
manifest = {'created': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'files': files, **digest}
(dest / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
print(f'{len(files)} Dateien im Manifest')
PY
tar -czf "${dest_base}/llm-infra-backup-${ts}.tar.gz" -C "${dest_base}" "${ts}"
rm -rf "${dest}"
printf '\nBackup fertig: %s\n' "${dest_base}/llm-infra-backup-${ts}.tar.gz"
printf 'Inhalt pruefen: ./scripts/restore.sh --list\n'
printf 'Achtung: Die ZFS-Snapshots bleiben liegen. Loeschen nur von Hand (bewusst):\n'
printf '  zfs list -t snapshot -o name,used | grep llm-infra\n'
