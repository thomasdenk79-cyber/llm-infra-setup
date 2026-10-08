#!/usr/bin/env bash
# Wiederholbarer Failover-Drill fuer die dreistufige Gateway-Kette:
#   Primaer (absichtlich tot) -> Stufe 2 Bonsai (:8082) -> Stufe 3 Luna (ChatGPT-OAuth).
#
#   ./scripts/litellm-failover-drill.sh              Durchlauf mit Zahlen
#   ./scripts/litellm-failover-drill.sh --no-luna    nur bis Stufe 2 beweisen
#
# Warum ein Testcontainer und nicht das lebende Gateway: ein Drill gegen die
# echte Pennyroyal-Kette wuerfe laufende Anfragen aller Agenten. Der Drill
# faehrt eine Kopie der Router-Konfiguration mit einem beweisbar toten Primaer
# (unbenutzter Port 4099) auf Container litellm-drill, Port 127.0.0.1:4013,
# und misst Zeit und Token/s je Stufe. Der lebende Gateway bleibt unbertroffen.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${LITELLM_IMAGE:=ghcr.io/berriai/litellm:v1.101.0}"
DRILL_NAME=litellm-drill
DRILL_PORT=4013
DRILL_DEAD_PORT=4099
with_luna=1
[[ "${1:-}" == "--no-luna" ]] && with_luna=0

envf="${HOME}/.config/llm-infra/gateway.env"
[[ -r "${envf}" ]] || { echo 'FEHLT: ~/.config/llm-infra/gateway.env (Master-Key fuer den Drill). Naechster Schritt: ./scripts/ensure-credentials.sh'; exit 1; }

cleanup() { podman rm -f "${DRILL_NAME}" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

work="$(mktemp -d)"
# Router-Konfiguration aus dem Repo uebernehmen, Primaer auf einen beweisbar
# toten Port umbiegen. Die Fallback-Kette bleibt exakt die produktive.
python3 - "$root/config/litellm.yaml" "$work/config.yaml" "${DRILL_DEAD_PORT}" <<'PY'
import re, sys
src, dst, dead = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(src).read()
text = re.sub(r'(model: openai/pennyroyal\n\s*api_base: )http://[^\n]+',
              rf'\g<1>http://127.0.0.1:{dead}/v1', text)
assert f'127.0.0.1:{dead}' in text, 'Prihmaeer-Umbiegung fehlgeschlagen'
open(dst, 'w').write(text)
PY
chmod 0600 "$work/config.yaml"   # enthaelt nur os.environ-Platzhalter, keine Werte

# Master-Key nur in diese Shell, nie ausgeben.
set -a; . "${envf}"; set +a

podman run -d --name "${DRILL_NAME}" \
  --network=llm-inference \
  -p 127.0.0.1:${DRILL_PORT}:4000 \
  --env-file "${envf}" \
  -e LITELLM_CONFIG=/etc/litellm/config.yaml \
  -e CHATGPT_TOKEN_DIR=/etc/chatgpt-tokens \
  -e MAX_STRING_LENGTH_STDOUT_LOG=600 \
  -v "${HOME}/.config/llm-infra/chatgpt-tokens:/etc/chatgpt-tokens:rw,Z" \
  -v "${work}/config.yaml:/etc/litellm/config.yaml:ro,Z" \
  "${LITELLM_IMAGE}" --config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0 >/dev/null

echo "== Warte auf Bohrer-Liveliness (max 2 min) =="
ok=0
for i in $(seq 1 40); do
  curl -fsS --max-time 2 "http://127.0.0.1:${DRILL_PORT}/health/liveliness" >/dev/null 2>&1 && { ok=1; break; }
  sleep 3
done
if [[ "${ok}" != 1 ]]; then
  echo 'FEHLER: Bohrer wurde nicht lebendig. Letzter Logauszug:'
  podman logs --tail 30 "${DRILL_NAME}" 2>&1 || true
  echo 'Naechster Schritt: podman logs litellm-drill'
  exit 1
fi
echo 'liveliness ok'

probe() {
  # probe <label> <model> [ohne_temperatur] - Zeit und Token/s in Python gemessen.
  # Luna (chatgpt-Anbieter) lehnt zusaetzliche Parameter wie temperature ab: bei
  # "notemp" bleibt die Anfrage auf model/messages/max_tokens beschraenkt.
  python3 - "$1" "$2" "${DRILL_PORT}" "${LITELLM_MASTER_KEY}" "${3:-}" <<'PY'
import json, sys, time, urllib.request
label, model, port, key = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
notemp = len(sys.argv) > 5 and sys.argv[5] == "notemp"
req_body = {"model": model,
            "messages": [{"role": "user", "content": "Answer with one short word."}],
            "max_tokens": 24}
if not notemp:
    req_body["temperature"] = 0
body = json.dumps(req_body).encode()
req = urllib.request.Request(f"http://127.0.0.1:{port}/v1/chat/completions", data=body,
                             headers={"Authorization": f"Bearer {key}",
                                      "Content-Type": "application/json"})
t0 = time.monotonic()
try:
    with urllib.request.urlopen(req, timeout=180) as r:
        d = json.loads(r.read().decode())
except Exception as exc:
    dt = time.monotonic() - t0
    print(f"STUFE-ERGEBNIS\t{label}\tFEHLER\tnach {dt:.2f}s: {exc}")
    raise SystemExit(1)
dt = time.monotonic() - t0
choice = d["choices"][0]
txt = (choice.get("message", {}).get("content") or "").strip().replace("\n", " ")[:60]
tok = d.get("usage", {}).get("completion_tokens", 0)
rate = tok / dt if dt > 0 else 0.0
model_ret = d.get("model", "?")
print(f"STUFE-ERGEBNIS\t{label}\t{dt:.2f}s\ttok={tok}\t{rate:.1f}tok/s\tmodell={model_ret}\taktuell={txt!r}")
PY
}

echo "== Stufe 1: Alias qwen3.8-flash-next gegen toten Prihmaeer (erwartet: Kette uebernimmt) =="
probe "tier1-kette" "qwen3.8-flash-next" || echo 'DRILL STUFE-1 FEHLGESCHLAGEN (Kette hat nicht geantwortet)'
echo "== Stufe 2: bonsai-2-27b direkt =="
probe "tier2-bonsai" "bonsai-2-27b" || echo 'DRILL STUFE-2 FEHLGESCHLAGEN'
echo "== Stufe 3: gpt-6-luna direkt =="
if [[ "${with_luna}" == 1 ]]; then
  probe "tier3-luna" "gpt-6-luna" notemp || echo 'DRILL STUFE-3 FEHLGESCHLAGEN (Token abgelaufen? siehe docs/troubleshooting.md)'
else
  echo "STUFE-ERGEBNIS  tier3-luna  uebersprungen (--no-luna)"
fi

echo "== Bohrer-Log: Nachweis der Weiterreichung =="
podman logs "${DRILL_NAME}" 2>&1 | grep -i -E 'falling back|cooldown|retrying|litellm_router' | tail -8 || true
echo 'Container wird beim Ende entfernt. Vollstaendiger Log waehrend des Laufs: podman logs -f litellm-drill'
