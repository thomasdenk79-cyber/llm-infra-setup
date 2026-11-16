#!/usr/bin/env bash
# Bringt die Doku-Werkzeuge (mkdocs) so, dass `make docs-build` laufen kann.
#
# mkdocs ist kein Systempaket auf diesem Rechner und soll auch keines werden:
# die Werkzeuge kommen in eine eigene Umgebung unter ~/.local/share/llm-infra,
# die Version steht in versions.lock (Zeile docs_tooling). Skript ist
# idempotent - zweiter Aufruf prueft nur und installiert nichts neu.
#
# Aufruf: ./scripts/install-docs-tooling.sh [--check]
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENV="${DOCS_VENV:-$HOME/.local/share/llm-infra/docs-venv}"
CHECK=0
[[ "${1:-}" == "--check" ]] && CHECK=1
[[ $# -gt 1 ]] && { echo "Benutzung: $0 [--check]" >&2; exit 2; }

Paket="$(sed -n 's/^docs_tooling:[[:space:]]*//p' "$REPO/versions.lock" | head -1)"
[[ -n "$Paket" ]] || { echo "versions.lock nennt kein docs_tooling - nachtragen, dann erneut." >&2; exit 1; }

if [[ -x "$VENV/bin/mkdocs" ]] && "$VENV/bin/python" -c 'import material, mkdocs' >/dev/null 2>&1; then
  echo "Doku-Werkzeuge vorhanden: $("$VENV/bin/mkdocs" --version 2>/dev/null | head -1) in $VENV"
  echo "weiter: make docs-build"
  exit 0
fi

if [[ "$CHECK" == "1" ]]; then
  echo "Doku-Werkzeuge fehlen. Weiter mit: ./scripts/install-docs-tooling.sh" >&2
  exit 1
fi

echo "Umgebung $VENV fuer $Paket anlegen ..."
mkdir -p "$(dirname "$VENV")"
if command -v uv >/dev/null 2>&1; then
  uv venv "$VENV" >/dev/null
  uv pip install --python "$VENV/bin/python" "$Paket" >/dev/null
else
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet "$Paket"
fi
[[ -x "$VENV/bin/mkdocs" ]] || { echo "mkdocs fehlt nach Installation in $VENV - Ursache im Pip-Ausgabeblock suchen." >&2; exit 1; }
echo "installiert: $("$VENV/bin/mkdocs" --version 2>/dev/null | head -1)"
echo "weiter: make docs-build"
