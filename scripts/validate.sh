#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${root}"
command -v shellcheck >/dev/null 2>&1 && shellcheck scripts/*.sh lib/*.sh || true
git diff --check
# Lightweight repository secret guard; real credentials must stay in ignored files.
if rg -n --hidden -g '!state/**' -g '!.git/**' -g '!setup_prompt.md' '(hf_[A-Za-z0-9]{20,}|sk-[A-Za-z0-9]{20,}|BEGIN (OPENSSH|RSA|EC) PRIVATE KEY)' .; then echo 'Potential secret detected' >&2; exit 1; fi
for required in AGENTS.md README.md CHANGELOG.md versions.lock mkdocs.yml docs/adr; do [[ -e "$required" ]] || { echo "Missing required path: $required" >&2; exit 1; }; done
if command -v python >/dev/null 2>&1; then python - <<'PY'
import json, pathlib
for p in pathlib.Path('.').rglob('*.json'):
    json.loads(p.read_text())
print('JSON validation: OK')
PY
fi
if command -v python >/dev/null 2>&1; then python -m py_compile tui/llmctl.py; fi
echo 'Repository validation: OK'
