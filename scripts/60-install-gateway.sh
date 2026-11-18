#!/usr/bin/env bash
# LiteLLM-Gateway: Quadlet-Unit und Router-Konfiguration erzeugen.
#
#   ./scripts/60-install-gateway.sh           Unit und Konfiguration erzeugen
#   ./scripts/60-install-gateway.sh --check   nur pruefen, nichts aendern
#
# Der Gateway haengt am Inferenz-Netz, hoert auf dem Host nur auf 127.0.0.1 und
# zieht seine Zugangswerte aus ~/.config/llm-infra/gateway.env (0600, nie in Git).
# Oeffentlich erreichbar ist er ausschliesslich ueber den Gateway-VM-Caddy
# (scripts/70-setup-gateway-proxy.sh) - und dort nur mit persoenlichem
# Virtual-Key aus der PostgreSQL, nicht mit dem Master-Key.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"

check_only=0
[[ "${1:-}" == "--check" ]] && check_only=1

[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
[[ -f "$root/config/model.env" ]] && source "$root/config/model.env"
[[ -f "$root/config/gateway.env" ]] && source "$root/config/gateway.env"
# Lokale Laufzeit-Secrets aus derselben Env-Datei wie die Quadlet sie zieht.
# Nur ins Gedaechtnis laden, niemals ausgeben.
secrets_file="${LLM_INFRA_SECRETS_DIR:-${HOME}/.config/llm-infra}/gateway.env"
[[ -f "$secrets_file" ]] && source "$secrets_file"

# --- stabile Vorgaben (in versions.lock gepinnt) ---------------------------
: "${LITELLM_IMAGE:=docker.litellm.ai/berriai/litellm:v1.105.0}"
: "${LITELLM_PORT:=4000}"
# Primaerer lokaler Upstream. Solange die Runtime nicht im Inferenz-Netz laeuft,
# ist das der Host-Port des Runtime-Forwarders; danach http://llm-runtime:8000/v1.
: "${FLASH_NEXT_API_BASE:=http://host.containers.internal:30001/v1}"
# Bonsai-Stufe der Faellkette: eigener Host ist nicht installiert; die Defaults verweisen
# auf einen unerreicherbaren Namen, damit die Stufe sauber durchfaellt statt an einer
# fehlenden Umgebungsvariablen zu scheitern (Befund der Review-Welle 2026-11-18).
: "${BONSAI_BASE_URL:=http://bonsai.unreachable.invalid:8082/v1}"
: "${BONSAI_API_KEY:=sk-local-bonsai}"
: "${FLASH_NEXT_API_KEY:=sk-local-vllm}"
: "${BONSAI_BASE_URL:=http://bonsai:8082/v1}"

unit_file="${UNIT_DIR}/litellm.container"

if [[ "${check_only}" == 1 ]]; then
  missing=0
  [[ -f "${unit_file}" ]] || { printf 'FEHLT: %s ist nicht installiert\n' "${unit_file}"; missing=1; }
  unit_is_active litellm.service || { printf 'FEHLT: litellm.service laeuft nicht\n'; missing=1; }
  [[ -f "$secrets_file" ]] || { printf 'FEHLT: %s fehlt\n' "$secrets_file"; missing=1; }
  [[ "${missing}" == 0 ]] && printf 'OK: Gateway vollstaendig\n'
  exit "${missing}"
fi

# --- Defaults in die Secret-Datei schreiben (idempotent, keine Ausgabe) ----
# FLASH_NEXT_* sind keine Geheimnisse (lokale Runtime ohne Authentifizierung),
# gehoren aber zur selben Datei, damit Container und Clients gleichziehen.
if [[ -d "$(dirname -- "$secrets_file")" ]]; then
  for pair in "FLASH_NEXT_API_BASE=${FLASH_NEXT_API_BASE}" "FLASH_NEXT_API_KEY=${FLASH_NEXT_API_KEY}" "BONSAI_BASE_URL=${BONSAI_BASE_URL}" "BONSAI_API_KEY=${BONSAI_API_KEY}"; do
    key="${pair%%=*}"
    grep -q "^${key}=" "$secrets_file" 2>/dev/null && continue
    printf '%s\n' "$pair" >> "$secrets_file"
    chmod 600 "$secrets_file"
    log "ergaenzt in der lokalen Env-Datei: ${key}"
  done
fi

# Die geteilte Credential-Datei fuer andere Clients bleibt erhalten. Der
# Container bekommt sie bereinigt: LLM_INFRA_API_KEY ist ein Client-Schluessel,
# LITELLM_MASTER_KEY muss drinbleiben, weil der Gateway damit Virtual-Keys der
# Kollegen prueft und die Admin-Rufe (/key/generate) absichert.
mkdir -p "$(dirname -- "${secrets_file}")"
if [[ -f "$secrets_file" ]]; then
  awk '!/^LLM_INFRA_API_KEY=/' "$secrets_file" > "${secrets_file%/*}/litellm.env"
  chmod 600 "${secrets_file%/*}/litellm.env"
fi

# Ordner fuer die Geraet-Token des dritten Falls: Podman scheitert mit status=125,
# wenn die Quelle einer Bind-Mounts fehlt - also vor dem Start anlegen.
install -d -m 0700 "${secrets_file%/*}/chatgpt-tokens"

install -d "$root/quadlet"
cat > "$root/quadlet/litellm.container" <<UNIT
# GENERIERT von scripts/60-install-gateway.sh - dort ändern, nicht hier.
[Unit]
Description=LiteLLM API gateway
After=litellm-postgres.service
Wants=llm-inference-network.service

[Container]
Image=${LITELLM_IMAGE}
ContainerName=litellm
Network=llm-inference.network
NetworkAlias=litellm
PublishPort=127.0.0.1:${LITELLM_PORT}:4000
EnvironmentFile=%h/.config/llm-infra/litellm.env
Environment=LITELLM_CONFIG=/etc/litellm/config.yaml
# Kuerzt Python-Stacktraces im stdout-Log (LiteLLM trunciert Logs ueber diese
# env-Variable; ohne sie blaest ein einziger Upstream-Fehler das Journal mit
# ~10 kB Traceback pro Request - siehe MAX_STRING_LENGTH_STDOUT_LOG in
# litellm/constants.py dieser Version).
Environment=MAX_STRING_LENGTH_STDOUT_LOG=600
# ChatGPT-OAuth-Token fuer den dritten Fallback (Luna). Bleibt lokal unter
# dem Betreiber-Verzeichnis, nie in Git; Geraet-Login erzeugt es selbst.
Environment=CHATGPT_TOKEN_DIR=/etc/chatgpt-tokens
Volume=%h/.config/llm-infra/chatgpt-tokens:/etc/chatgpt-tokens:rw,Z
Volume=@CONFIG_ROOT@/config/litellm.yaml:/etc/litellm/config.yaml:ro,Z
Exec=--config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT

install -d "$root/config"
cat > "$root/config/litellm.yaml" <<'YAML'
# LiteLLM-Router dieses Stacks. Werte, die der Rechner bestimmt, kommen aus
# os.environ (Datei ~/.config/llm-infra/gateway.env, Modus 0600, nie in Git).
#
# Modellfamilien:
#   direct-* / standard-* / local-*  Profile derselben lokalen Runtime
#       (qwen3.8-flash-next). Sie unterscheiden sich nur in Reasoning-Aufwand
#       und Kontextfenster, damit Agenten ein passendes Profil waehlen koennen,
#       statt selbst Parameter zu raten.
#   qwen3.8-flash-next               kanonischer Name fuer den automatischen
#       lokalen Pfad; Faellkette qwen3.8-flash-next -> bonsai-2-27b -> gpt-6-luna.
#   deepseek-v4.1-flash,
#   siemens-qwen-3.8-27b             Siemens-Review-/Benchmark-Ziele, bewusst
#       NICHT in der Faellkette: Messung 2026-10-08 (512 Token, n=3 je Modell)
#       DeepSeek median 31,81 s (16,24-72,13 s), Siemens-Qwen median 20,11 s
#       (2,50-96,35 s) - zu hohe Varianz fuer den interaktiven Kernpfad.
#
# Fail-fast: Retries der lokalen Stufen stehen auf 0. Mit globalen Retries
# kostete jede Anfrage ~22 s, weil bei nur einem Deployment pro Modellname nie
# ein Cooldown greift. Fehler -> sofort naechste Stufe (<1 s).
model_list:
  - model_name: qwen3.8-flash-next
    model_info:
      max_input_tokens: 524288
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      num_retries: 0
      max_retries: 0
      timeout: 600

  - model_name: direct-short-none
    model_info:
      max_input_tokens: 131808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: none
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: direct-medium-xhigh
    model_info:
      max_input_tokens: 241808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: direct-long-xhigh
    model_info:
      max_input_tokens: 461808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600

  - model_name: standard-efficient
    model_info:
      max_input_tokens: 81552
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: none
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: standard-balanced
    model_info:
      max_input_tokens: 241664
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: standard-intelligent
    model_info:
      max_input_tokens: 499712
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600

  - model_name: local-short-none
    model_info:
      max_input_tokens: 131808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: none
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: local-medium-xhigh
    model_info:
      max_input_tokens: 241808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: local-long-xhigh
    model_info:
      max_input_tokens: 461808
      max_output_tokens: 8192
    litellm_params:
      model: openai/qwen3.8-flash-next
      api_base: os.environ/FLASH_NEXT_API_BASE
      api_key: os.environ/FLASH_NEXT_API_KEY
      reasoning_effort: xhigh
      num_retries: 0
      max_retries: 0
      timeout: 600

  - model_name: bonsai-2-27b
    model_info:
      max_input_tokens: 250000
    litellm_params:
      model: openai/bonsai-2-27b
      api_base: os.environ/BONSAI_BASE_URL
      api_key: "sk-local-bonsai"
      num_retries: 0
      max_retries: 0
      timeout: 300

  - model_name: gpt-6-luna
    model_info:
      mode: responses
      max_input_tokens: 272000
    litellm_params:
      model: chatgpt/gpt-6-luna
      reasoning_effort: high

  - model_name: deepseek-v4.1-flash
    litellm_params:
      model: openai/deepseek-v4.1-flash
      api_base: https://api.siemens.com/llm/v1
      api_key: "os.environ/SIEMENS_LLM_API_KEY"
  - model_name: siemens-qwen-3.8-27b
    litellm_params:
      model: openai/qwen-3.8-27b
      api_base: https://api.siemens.com/llm/v1
      api_key: "os.environ/SIEMENS_LLM_API_KEY"

router_settings:
  num_retries: 3
  retry_after: 5
  allowed_fails: 3
  cooldown_time: 60
  context_window_fallbacks:
    - bonsai-2-27b: ["gpt-6-luna"]
    - standard-intelligent: ["standard-balanced"]
    - standard-balanced: ["standard-efficient"]
  fallbacks:
    - qwen3.8-flash-next: ["bonsai-2-27b", "gpt-6-luna"]
    - standard-intelligent: ["standard-balanced"]
    - standard-balanced: ["standard-efficient"]

general_settings:
  # Virtuelle Schluessel der Kollegen liegen in dieser PostgreSQL. Der
  # Master-Key kommt aus der Env-Datei; er ermoeglicht die Admin-Rufe und
  # schaltet die Authentifizierung ein. Ohne ihn bleibt der Gateway zu -
  # gewollt, denn ein offener Gateway liegt hinter dem oeffentlichen Port.
  database_url: "os.environ/DATABASE_URL"

litellm_settings:
  drop_params: true
  request_timeout: 600
YAML

# Die dritte Faellstufe (chatgpt/gpt-6-luna) verlangt einen interaktiven
# Geraetelogin bei OpenAI. Ohne gespeicherte Token ruft der Proxy beim Start
# den Geraetefluss auf, der Endpunkt 4000 bindet nicht - der Gateway bliebe
# also stumm, ohne dass ein Fehler dazu fuehrt. Deshalb wird die Stufe nur
# aufgenommen, wenn der Betreiber den Login einmalig durchgefuehrt hat.
# Achtung: der Proxy legt im Token-Ordner auch eine reine Merkdatei mit
# Geraeteanfrage-Zeitstempel ab - die zehlt nicht als Anmeldung.
luna_aktiv() {
  python3 - "${secrets_file%/*}/chatgpt-tokens" <<'PY'
import json
import pathlib
import sys
root = pathlib.Path(sys.argv[1])
for datei in sorted(root.glob("*.json")):
    try:
        daten = json.loads(datei.read_text())
    except (OSError, ValueError):
        continue
    if isinstance(daten, dict) and any(daten.get(schluessel) for schluessel in ("access_token", "refresh_token", "tokens", "token_bundle")):
        sys.exit(0)
sys.exit(1)
PY
}
if ! luna_aktiv; then
  python3 - "$root/config/litellm.yaml" <<'PY'
import re
import sys
path = sys.argv[1]
text = open(path).read()
text = re.sub(r"\n  - model_name: gpt-6-luna.*?(?=\n  - model_name:)", "\n", text, flags=re.S)
text = text.replace('    - bonsai-2-27b: ["gpt-6-luna"]\n', "")
text = text.replace('["bonsai-2-27b", "gpt-6-luna"]', '["bonsai-2-27b"]')
open(path, "w").write(text)
PY
  log "dritte Faellstufe gpt-6-luna ohne Geraet-Token ausgelassen"
  log "aktivieren: Geraetelogin laeuft Token unter ~/.config/llm-infra/chatgpt-tokens ab, dann ./scripts/60-install-gateway.sh erneut ausfuehren"
fi

log 'LiteLLM Quadlet und Router-Konfiguration erzeugt.'
cat <<NEXT
Unit ist installiert und geladen. Starten: ./scripts/deploy-non-gpu.sh
Pruefen:  curl -s http://127.0.0.1:${LITELLM_PORT}/health/liveliness
Schluesselvergabe: ./scripts/71-gateway-keys.sh
NEXT
