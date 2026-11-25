#!/usr/bin/env bash
# Sichert alles, was man zum Wiederherstellen braucht - ohne Modellmassen zu kopieren.
#
#   ./scripts/backup.sh                 Backup in state/backups/
#   ./scripts/backup.sh /pfad/ziel      anderes Zielverzeichnis
#   ./scripts/backup.sh --install       taeglichen Timer einrichten (Persistent)
#   ./scripts/backup.sh --uninstall     Timer wieder entfernen
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
if [[ "${1:-}" == "--install" ]]; then
  source "${root}/lib/units.sh"
  install_systemd_units "${HOME}/.config/systemd/user" llm-backup.service llm-backup.timer
  systemctl --user daemon-reload
  systemctl --user enable --now llm-backup.timer
  log 'Backup-Timer aktiv (taeglich 03:10, verpasste Laeufe werden nachgeholt).'
  exit 0
fi
if [[ "${1:-}" == "--uninstall" ]]; then
  systemctl --user disable --now llm-backup.timer 2>/dev/null || true
  rm -f "${HOME}/.config/systemd/user/llm-backup.service" "${HOME}/.config/systemd/user/llm-backup.timer"
  systemctl --user daemon-reload
  log 'Backup-Timer entfernt.'
  exit 0
fi
dest_base="${1:-${root}/state/backups}"
ts="$(date -u +%Y%m%dT%H%M%SZ)"
dest="${dest_base}/${ts}"
install -d -m 0700 "${dest}"

# Ein Teil, der stillschweigend fehlt, macht aus dem Backup eine Taetigung.
# Die alte Form `tar ... && log ...` loest kein errexit aus: innerhalb einer
# &&-Kette ist nur der letzte Befehl massgeblich, und das war hier das log, das im
# Fehlerfall gar nicht lief. Der Archivaufbau endete trotzdem mit 0 und meldete
# 'Backup fertig', waehrend Grafanas Ausfuhrordner fehlten. Deshalb wird jetzt
# jeder Teil gezaehlt und am Ende entschieden.
teile_fehlend=()

items=(); for item in config quadlet systemd containers docs Makefile versions.lock mkdocs.yml AGENTS.md README.md; do
  [[ -e "${root}/${item}" ]] && items+=("${item}")
done
if tar --exclude='config/*.env' --exclude='config/homepage/.secret.env' -czf "${dest}/repository-config.tar.gz" -C "${root}" "${items[@]}"; then
  log 'Konfiguration gespeichert.'
else
  teile_fehlend+=('Konfiguration aus dem Repo')
fi

# Betreiber-Einstellungen aus config/host.env: die Datei legt Pfade, Ports und den
# Containernamen fest und wird von keinem Skript neu erzeugt - nach einem Totalausfall
# waeren sie weg. Mit in die Sicherung, aber ohne Zugangswerte: Zeilen, deren Name
# nach Schluessel, Token, Passwort oder Secret aussieht, bleiben draussen; dafuer ist
# ensure-credentials.sh zustaendig.
if [[ -f "${root}/config/host.env" ]]; then
  if grep -qvE '^[[:space:]]*(#|$)' "${root}/config/host.env"; then
    if grep -vE '^[[:space:]]*[A-Za-z_]*(API_?KEY|TOKEN|SECRET|PASSWORT|PASSWORD|PASS)[A-Za-z_]*=' \
         "${root}/config/host.env" > "${dest}/host.env"; then
      chmod 0600 "${dest}/host.env"
      log 'Betreiber-Einstellungen gespeichert (ohne Zugangswerte).'
    else
      teile_fehlend+=('Betreiber-Einstellungen aus config/host.env')
    fi
  fi
fi

if command -v podman >/dev/null 2>&1 && \
   [[ "$(podman ps --format '{{.Names}}' 2>/dev/null || true)" == *litellm-postgres* ]]; then
  # shellcheck disable=SC1090
  source "${SECRETS_DIR}/postgres.env" 2>/dev/null || { POSTGRES_DB=litellm; POSTGRES_USER=litellm; }
  podman exec litellm-postgres pg_dump -U "${POSTGRES_USER:-litellm}" -d "${POSTGRES_DB:-litellm}" \
    > "${dest}/litellm-postgres.sql" 2>"${dest}/pg_dump.err" || {
      log 'WARNUNG: pg_dump fehlgeschlagen (Details in pg_dump.err).'; teile_fehlend+=('Datenbank-Inhalt'); }
  if [[ -s "${dest}/litellm-postgres.sql" ]]; then
    log 'Datenbank gespeichert.'
    rm -f "${dest}/pg_dump.err"
  else
    teile_fehlend+=('Datenbank-Inhalt (leerer Auszug)')
  fi
else
  log 'Datenbank-Container laeuft nicht; kein Datenbankteil im Backup.'
  teile_fehlend+=('Datenbank-Inhalt (Container laeuft nicht)')
fi

for dir in open-webui grafana homepage; do
  src="${HOME}/.local/share/llm-infra/${dir}"
  [[ -d "${src}" ]] || continue
  # Grafana legt Ausfuhren (png/csv/pdf) ab; die hoeren dem Nutzer des Containers
  # und sind bei Bedarf neu erzeugbare Ausfuhren, kein Zustand. Ohne Ausschluss
  # scheitert tar beim Oeffnen genau dieser Ordner - ein echter Fehler, der bisher
  # nur auf stderr zu sehen war. Alles andere bleibt ein Anlassteil.
  ausschluss=()
  if [[ "${dir}" == 'grafana' ]]; then
    ausschluss=(--exclude='grafana/png' --exclude='grafana/csv' --exclude='grafana/pdf')
  fi
  if tar "${ausschluss[@]}" -czf "${dest}/state-${dir}.tar.gz" -C "$(dirname "${src}")" "$(basename "${src}")"; then
    log "Zustand ${dir} gespeichert."
  else
    teile_fehlend+=("Zustand ${dir}")
  fi
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
chmod 0600 "${dest_base}/llm-infra-backup-${ts}.tar.gz"   # enthaelt pg_dump und host.env-Kopie
rm -rf "${dest}"
archiv="${dest_base}/llm-infra-backup-${ts}.tar.gz"

# Selbstpruefung: 'fertig' soll heissen, dass das Archiv sich selbst und seine
# Pruefsummen hat - nicht nur, dass tar mit 0 endete (genau da hatte ein frueherer
# Lauf drei Grafana-Ordner stillschweigend weggelassen).
if ./scripts/restore.sh --check "${archiv}" >"${STATE_DIR}/backup-check.log" 2>&1; then
  log 'Archiv selbst geprueft: Manifest und Pruefsummen stimmen.'
else
  teile_fehlend+=('Selbstpruefung des Archivs')
  printf '  Nachlesen: %s\n' "${STATE_DIR}/backup-check.log"
fi

# Aufbewahrung: die Archive sind hunderte MB gross. Ohne Grenze laeuft der Ordner
# voll und die Sicherung hort auf zu funktionieren - behalten wird die neueste Zahl
# aus LLM_BACKUP_ANZAHL, und das nur, wenn der neue Lauf vollstaendig war.
if (( ${#teile_fehlend[@]} == 0 )); then
  : "${LLM_BACKUP_ANZAHL:=3}"
  while IFS= read -r alt; do
    [[ -n "${alt}" ]] || continue
    rm -f "${alt}" && log "alte Sicherung entfernt: $(basename "${alt}")"
  done < <(ls -1t "${dest_base}"/llm-infra-backup-*.tar.gz 2>/dev/null | tail -n +"$((LLM_BACKUP_ANZAHL + 1))")
fi

if (( ${#teile_fehlend[@]} > 0 )); then
  printf '\n\033[31mBackup unvollstaendig:\033[0m %s\n' "$(IFS=', '; printf '%s\n' "${teile_fehlend[*]}")"
  printf '  Das Archiv liegt trotzdem da (lueckenhaft): %s\n' "${archiv}"
  printf '  Naechster Befehl: %s\n' './scripts/doctor.sh   # zeigt, welcher Dienst nicht laeuft'
  exit 1
fi
printf '\nBackup fertig und geprueft: %s\n' "${archiv}"
printf 'Inhalt pruefen: ./scripts/restore.sh --list\n'
printf 'Achtung: Die ZFS-Snapshots bleiben liegen. Loeschen nur von Hand (bewusst):\n'
printf '  zfs list -t snapshot -o name,used | grep llm-infra\n'
