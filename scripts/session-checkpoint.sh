#!/usr/bin/env bash
# Arbeitsstand sichern: Handoff-Seite aktualieren, alles committen, pushen.
#
#   ./scripts/session-checkpoint.sh                      Standardfall nach jedem Schritt
#   ./scripts/session-checkpoint.sh "kurze Notiz"        Notiz in die Handoff-Seite
#   ./scripts/session-checkpoint.sh --ohne-pruefung      Pruefung ueberspringen (nur im Notfall)
#   ./scripts/session-checkpoint.sh --status             zeigen, was ungesichert ist
#
# Warum das ein Skript ist: das Repository ist der einzige Rueckhalt nach einem
# Abbruch (Sitzung weg, Rechner neu gestartet, Agent gewechselt). Ein Lauf kostet
# wenige Sekunden und ersetzt das Merkmal "mach ich spaet".
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
# shellcheck source=common.sh
source "${root}/lib/common.sh"
handoff="docs/HANDOFF.md"
skip_check=0
note=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ohne-pruefung) skip_check=1; shift ;;
    --status)
      echo "Ungesicherte Aenderungen:"
      git status --short
      echo
      echo "Letzter Sicherungslauf: $(grep -m1 'Zuletzt gesichert' "${handoff}" 2>/dev/null || echo 'keiner')"
      echo "Letzter Push:          $(git log -1 --format='%h %ad %s' --date=iso)"
      exit 0
      ;;
    *) note="$1"; shift ;;
  esac
done

if [[ "${skip_check}" == 0 ]]; then
  log 'kurze Pruefung vor dem Sichern'
  bash -n scripts/*.sh lib/*.sh setup.sh
  ./scripts/validate.sh >/dev/null || { echo 'Pruefung fehlgeschlagen - nicht gesichert.' >&2; exit 1; }
fi

# Handoff-Seite aktualisieren
if [[ ! -f "${handoff}" ]]; then
  printf '# Handoff\n' > "${handoff}"
fi
TMP="$(mktemp)"
if grep -q '^Zuletzt gesichert:' "${handoff}"; then
  sed "s|^Zuletzt gesichert:.*|Zuletzt gesichert: $(date -Is) durch \`scripts/session-checkpoint.sh\`|" "${handoff}" > "${TMP}"
else
  { printf 'Zuletzt gesichert: %s durch `scripts/session-checkpoint.sh`\n\n' "$(date -Is)"; cat "${handoff}"; } > "${TMP}"
fi
mv "${TMP}" "${handoff}"
if [[ -n "${note}" ]]; then
  printf '\n## Notiz %s\n\n%s\n' "$(date -Is)" "${note}" >> "${handoff}"
fi

# Unabhaengig vom Inhalt: Stand mit Protokollierung sichern.
git add -A
if git diff --cached --quiet; then
  echo 'Nichts zu sichern (Arbeitsverzeichnis wie im letzten Commit).'
else
  git commit -q -m "stand: $(date +%Y-%m-%d\\ %H:%M) gesichert ($(git diff --cached --name-only | wc -l) Dateien)"
fi
if git push 2>&1 | tail -2; then
  echo "Stand gesichert und gepusht: $(git log -1 --format='%h %s')"
else
  echo 'PUSH FEHLGESCHLAGEN - der Stand ist nur lokal sicher. Pruefen: git remote -v' >&2
  exit 1
fi
git status --short --branch | head -3
