#!/usr/bin/env bash
# Bringt der lokalen opencode-Konfiguration bei, frueh zu verdichten und die
# richtige Kontextgroesse zu kennen - ohne vorhandene Einstellungen zu zerstoeren.
#
#   ./scripts/configure-opencode-client.sh              zeigen, was geaendert wuerde
#   ./scripts/configure-opencode-client.sh --schreiben  aendern (mit Sicherungskopie)
#
# Warum: die Laufzeit speichert insgesamt 824384 Token fuer ALLE gleichzeitigen
# Anfragen. Zwei grosse und eine dritte Sitzung fuellen das; der Rest wird
# verdraengt und muss neu gelesen werden (Vorlaufzeit springt). Verdichten und
# das Abschneiden alter Werkzeug-Ausgaben verhindert das.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${OPENCODE_MODEL_KEY:=}"   # leer = aus config["model"] abgeleitet
: "${OPENCODE_CONTEXT_BUDGET:=200000}"
target="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode/opencode.json"
write=0
[[ "${1:-}" == "--schreiben" ]] && write=1

if [[ ! -f "${target}" ]]; then
  echo "Es gibt noch keine ${target}."
  echo "Anlegen mit der Vorschlagdatei (fuegt nichts bestehendes zusammen):"
  echo "  cp ${target}.llm-infra ${target}   (oder: ./setup.sh, das legt sie an, wenn sie fehlt)"
  exit 0
fi

OPENCODE_TARGET="${target}" OPENCODE_MODEL_KEY="${OPENCODE_MODEL_KEY}" \
OPENCODE_PORT="${PENNYROYAL_PORT}" OPENCODE_BUDGET="${OPENCODE_CONTEXT_BUDGET}" \
python3 - "${write}" <<'PY'
import datetime, json, os, pathlib, shutil, sys

write = sys.argv[1] in ("--schreiben", "1")
path = pathlib.Path(os.environ["OPENCODE_TARGET"])
budget = int(os.environ["OPENCODE_BUDGET"])
port = os.environ["OPENCODE_PORT"]
config = json.loads(path.read_text())

# Der aktuell gewaehlte Schluessel ist massgeblich, sonst stellt man die Grenze fuer
# ein Modell ein, das gar nicht benutzt wird.
model_key = os.environ["OPENCODE_MODEL_KEY"] or str(config.get("model", "")).split("/")[-1] or "pennyroyal"

wanted = {
    "compaction": {"auto": True, "prune": True, "reserved": 16000},
}
provider = config.setdefault("provider", {}).setdefault("local-pennyroyal", {})
model = provider.setdefault("models", {}).setdefault(model_key, {})
model["limit"] = {"context": budget, "output": 32000}
provider.setdefault("options", {}).update({
    "baseURL": f"http://127.0.0.1:{port}/v1",
    # Kein Chunk-Timeout: ein langer Gedanke bei 4 gleichzeitigen Anfragen kann
    # sonst als abgebrochene Verbindung enden.
    "chunkTimeout": 600000,
})
for key, value in wanted.items():
    current = config.get(key) or {}
    merged = {**current, **value}      # vorhandene Schluessel (z. B. tail_turns) bleiben
    if current != merged:
        print(f"  {key}: {json.dumps(current)} -> {json.dumps(merged)}")

print(f"  provider.local-pennyroyal.models.{model_key}.limit.context = {budget}")
if not write:
    print("\nTrockenlauf. Anwenden mit: ./scripts/configure-opencode-client.sh --schreiben")
    raise SystemExit(0)
stempel = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
backup = path.with_suffix(path.suffix + f".vor-llm-infra-{stempel}")
shutil.copy2(path, backup)
for key, value in wanted.items():
    config[key] = {**(config.get(key) or {}), **value}
path.write_text(json.dumps(config, indent=2, ensure_ascii=False) + "\n")
print(f"\nGeschrieben. Sicherungskopie: {backup}")
print("Wirksam nach einem Neustart von opencode (die laufende Sitzung behaelt ihren Kontext).")
PY
