#!/usr/bin/env bash
# Gehaefteter Wiederherstellungspfad. Nichts hier loescht Nutzdaten, ohne dass
# ausdruecklich bestaetigt wurde.
#
#   ./scripts/restore.sh --list
#   ./scripts/restore.sh --check   state/backups/<stempel>      Manifest pruefen
#   ./scripts/restore.sh config    state/backups/<stempel>      Repo-Konfiguration zurueckholen
#   ./scripts/restore.sh database  state/backups/<stempel>      LiteLLM-Datenbank einspielen
#
# Reihenfolge nach Totalausfall:
#   1. Repo aus Git holen:        git clone <dein Repo> && cd llm-infra-setup
#   2. Zugangsdaten neu erzeugen:  ./scripts/ensure-credentials.sh
#   3. Konfiguration zurueck:      ./scripts/restore.sh config state/backups/<stempel>
#   4. Datenbank zurueck:          ./scripts/restore.sh database state/backups/<stempel>
#   5. Stack starten:              make deploy-ready
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"

list() {
  local base="${1:-${root}/state/backups}"
  [[ -d "${base}" ]] || { echo 'Kein Backup-Verzeichnis gefunden.'; return 0; }
  echo 'Backups (neueste zuerst):'
  ls -1t "${base}"/*.tar.gz 2>/dev/null | sed 's|.*/||; s|^|  |' || echo '  keine'
  echo
  echo 'ZFS-Snapshots auf dem Modell-Dataset:'
  zfs list -t snapshot -H -o name,creation,used 2>/dev/null | grep llm-infra | sed 's|^|  |' || echo '  keine'
}

extract() {
  local base="$1" tarball
  [[ -d "${base}" ]] && return 0
  tarball="${base%.tar.gz}.tar.gz"
  [[ -f "${tarball}" ]] || { echo "Backup nicht gefunden: ${base} (auch nicht ${tarball})" >&2; exit 1; }
  base="$(mktemp -d)/$(basename "${tarball}" .tar.gz)"
  install -d -m 0700 "$(dirname "${base}")"
  tar -xzf "${tarball}" -C "$(dirname "${base}")"
  printf '%s\n' "${base}"
}

cmd="${1:---list}"
case "${cmd}" in
  --list|list) list "${2:-}" ;;
  --check|check)
    base="$(extract "${2:?pfad zum backup}" )"
    [[ -f "${base}/manifest.json" ]] || { echo 'manifest.json fehlt - Backup unvollstaendig.' >&2; exit 1; }
    python3 - "${base}" <<'PY'
import hashlib, json, pathlib, sys
base = pathlib.Path(sys.argv[1])
manifest = json.loads((base / 'manifest.json').read_text())
bad = []
for name, want in manifest['files'].items():
    p = base / name
    if not p.is_file():
        bad.append(f'fehlt: {name}'); continue
    if hashlib.sha256(p.read_bytes()).hexdigest() != want:
        bad.append(f'pruefsumme falsch: {name}')
extra = [str(p.relative_to(base)) for p in sorted(base.rglob('*'))
         if p.is_file() and p.relative_to(base).as_posix() not in manifest['files']
         and p.name != 'manifest.json']
print(f'{len(manifest["files"])} Dateien geprueft')
for b in bad: print('  ', b)
for e in extra: print('   zusaetzlich:', e)
print('MANIFEST OK' if not bad else 'MANIFEST FEHLERHALFT')
raise SystemExit(1 if bad else 0)
PY
    ;;
  config)
    base="$(extract "${2:?pfad zum backup}")"
    [[ -f "${base}/repository-config.tar.gz" ]] || { echo 'Kein repository-config.tar.gz im Backup.' >&2; exit 1; }
    stage="$(mktemp -d)"
    tar -xzf "${base}/repository-config.tar.gz" -C "${stage}"
    echo 'Wiederhergestellte Konfiguration (zum Vergleichen) liegt hier:'
    printf '  %s\n' "${stage}"
    echo 'Vergleich mit dem aktuellen Stand:'
    diff -rq "${stage}/config" "${root}/config" 2>&1 | head -20 || true
    echo
    echo 'Wenn das passt, uebernehmen:'
    printf '  cp -a %s/config/. %s/config/ && ./scripts/deploy-ready.sh\n' "${stage}" "${root}"
    echo 'Hinweis: Passwort-Dateien waren bewusst nicht im Backup; neu erzeugen mit'
    printf '  ./scripts/ensure-credentials.sh\n'
    ;;
  database)
    base="$(extract "${2:?pfad zum backup}")"
    dump="${base}/litellm-postgres.sql"
    [[ -f "${dump}" ]] || { echo 'Kein litellm-postgres.sql im Backup.' >&2; exit 1; }
    echo 'Einspielen in die laufende LiteLLM-Datenbank?'
    echo 'Das ueberschreibt den aktuellen Datenbankinhalt.'
    if [[ "${3:-}" != "--yes" ]]; then
      read -r -p 'Weiter mit J/N: ' reply
      [[ "${reply}" == J || "${reply}" == j ]] || { echo 'abgebrochen'; exit 1; }
    fi
    [[ -f "${SECRETS_DIR}/postgres.env" ]] || { echo 'Zuerst ./scripts/ensure-credentials.sh ausfuehren.' >&2; exit 1; }
    # shellcheck disable=SC1090
    source "${SECRETS_DIR}/postgres.env"
    [[ "$(podman ps --format '{{.Names}}' || true)" == *litellm-postgres* ]] \
      || { echo 'Datenbank laeuft nicht. Zuerst: make deploy-non-gpu' >&2; exit 1; }
    podman exec -i litellm-postgres psql -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" < "${dump}"
    systemctl --user restart litellm.service
    echo 'Datenbank eingespielt, Gateway neu gestartet.'
    ;;
  *) sed -n '2,20p' "$0"; exit 2 ;;
esac
