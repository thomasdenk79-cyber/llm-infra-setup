#!/usr/bin/env bash
# Baut das Hermes-Wiki neu, aber nur wenn es neue Commits gibt (Stand: site/.built-sha).
# Aufgerufen vom Timer wiki-rebuild.timer; manuell: ./scripts/wiki-rebuild.sh [--force]
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
: "${WIKI_DIR:=${HOME}/work/hermes-wiki}"
wiki="${WIKI_DIR}"
[[ -d "${wiki}" ]] || { log "Wiki-Repo nicht angelegt: ${wiki} - kein Fehlerfall auf Rechnern ohne Wiki."; exit 0; }
[[ -f "${wiki}/mkdocs.yml" ]] || { echo "mkdocs.yml fehlt in ${wiki}. Naechster Befehl: ./scripts/60-install-wiki.sh --first" >&2; exit 1; }
cd "${wiki}"
if git remote get-url origin >/dev/null 2>&1; then
  git fetch --quiet origin 2>/dev/null || true
  local_h="$(git rev-parse HEAD)"; rem_h="$(git rev-parse origin/main 2>/dev/null || echo "$local_h")"
  if [[ "$local_h" != "$rem_h" ]] && git merge-base --is-ancestor "$local_h" "$rem_h" 2>/dev/null; then
    git merge --ff-only origin/main && log "Wiki: auf origin/main aktualisiert"
  fi
fi
head_now="$(git rev-parse HEAD 2>/dev/null || echo NOGIT)"
stamp="$(cat .built-sha 2>/dev/null || echo none)"
if [[ "${1:-}" != "--force" && "$stamp" == "$head_now" ]]; then
  exit 0   # nichts zu tun; still sein (der Timer laeuft alle 30 min)
fi
venv=".venv/bin/mkdocs"
[[ -x "$venv" ]] || venv=".venv/Scripts/mkdocs.exe"   # Vollstaendigkeit halber
[[ -x "$venv" ]] || { echo "Wiki-venv fehlt. Naechster Befehl: ./scripts/60-install-wiki.sh --first" >&2; exit 1; }
# Atomar bauen: in ein frisches Verzeichnis, danach haengt ein Symlink um.
# Caddy bedient site/current, kein Request sieht jemals einen halben Stand.
build_dir="site/.build-${head_now:0:12}"
"$venv" build -f mkdocs.yml -d "$build_dir"
ln -sfn "$(basename "$build_dir")" site/.current.tmp
mv -T site/.current.tmp site/current
echo "$head_now" > .built-sha
# alte Build-Staende zuruecklassen, aber nur die letzten zwei
ls -1dt site/.build-* 2>/dev/null | tail -n +3 | xargs -r rm -rf
log "Wiki neu gebaut bei ${head_now:0:10}"
