#!/usr/bin/env bash
# Provisioniert Siemens LLM API-Key in der lokalen LiteLLM-Env, ohne ihn auszugeben.
# Aufruf: SIEMENS_LLM_KEY_FILE=/sicherer/pfad/token.txt ./scripts/65-configure-siemens-api.sh
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
key_file="${SIEMENS_LLM_KEY_FILE:-}"
if [[ -z "$key_file" || ! -r "$key_file" ]]; then
  echo "Key-Datei fehlt. Setze SIEMENS_LLM_KEY_FILE auf den lokalen Token-Dateipfad (Wert nie anzeigen)." >&2
  exit 2
fi
install -d -m 700 "$HOME/.config/llm-infra"
python3 - "$key_file" "$HOME/.config/llm-infra/gateway.env" <<'PY'
import os, pathlib, sys, tempfile
source, target = map(pathlib.Path, sys.argv[1:])
secret = source.read_text(encoding='utf-8-sig').strip()
if not secret:
    raise SystemExit('Key-Datei ist leer; nichts geaendert.')
lines = target.read_text().splitlines() if target.exists() else []
lines = [line for line in lines if not line.startswith('SIEMENS_LLM_API_KEY=')]
lines.append('SIEMENS_LLM_API_KEY=' + secret)
data = ('\n'.join(lines) + '\n').encode()
fd, tmp = tempfile.mkstemp(prefix='.gateway.env.', dir=target.parent)
try:
    os.fchmod(fd, 0o600)
    with os.fdopen(fd, 'wb') as f: f.write(data)
    os.replace(tmp, target)
finally:
    if os.path.exists(tmp): os.unlink(tmp)
os.chmod(target, 0o600)
print('Siemens API-Key aktualisiert (Wert unterdrueckt); gateway.env bleibt Modus 0600.')
PY
"$root/scripts/60-install-gateway.sh"
echo "Modelle neu generiert. Naechster Schritt nach Laufzeit-Pruefung: Gateway im Leerlauf sicher neu starten."
