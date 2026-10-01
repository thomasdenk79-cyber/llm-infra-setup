#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/*.sh lib/*.sh || true
git diff --check
if command -v python >/dev/null 2>&1; then python - <<'PY'
import json, pathlib
for p in pathlib.Path('.').rglob('*.json'):
    json.loads(p.read_text())
print('JSON validation: OK')
PY
fi
echo 'Repository validation: OK'
