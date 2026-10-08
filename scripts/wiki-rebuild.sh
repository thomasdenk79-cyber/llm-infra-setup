#!/usr/bin/env bash
# Baut das Hermes-Wiki neu, aber nur wenn es neue Commits gibt (Stand: site/.built-sha).
# Aufgerufen vom Timer wiki-rebuild.timer; manuell: ./scripts/wiki-rebuild.sh [--force]
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
wiki="${HOME}/work/hermes-wiki"
[[ -f "${wiki}/mkdocs.yml" ]] || { log "Wiki-Repo nicht gefunden: ${wiki} (make wiki installieren)"; exit 0; }
cd "${wiki}"
if git remote get-url origin >/dev/null 2>&1; then
  git fetch --quiet origin 2>/dev/null || true
  local_h="$(git rev-parse HEAD)"; rem_h="$(git rev-parse origin/main 2>/dev/null || echo "$local_h")"
  if [[ "$local_h" != "$rem_h" ]] && git merge-base --is-ancestor "$local_h" "$rem_h" 2>/dev/null; then
    git merge --ff-only origin/main && log "Wiki: auf origin/main aktualisiert"
  fi
fi
head_now="$(git rev-parse HEAD 2>/dev/null || echo NOGIT)"
stamp="$(cat site/.built-sha 2>/dev/null || echo none)"
if [[ "${1:-}" != "--force" && "$stamp" == "$head_now" ]]; then
  exit 0   # nichts zu tun; still sein (der Timer laeuft alle 30 min)
fi
venv=".venv/bin/mkdocs"
[[ -x "$venv" ]] || venv=".venv/Scripts/mkdocs.exe"   # Vollstaendigkeit halber
[[ -x "$venv" ]] || { log "Wiki-venv fehlt: python3 -m venv .venv && .venv/bin/pip install mkdocs-material (in ${wiki})"; exit 0; }
"$venv" build -f mkdocs.yml -d site
mkdir -p site && echo "$head_now" > site/.built-sha
log "Wiki neu gebaut bei ${head_now:0:10}"
