#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
[[ -f "$root/config/model.env" ]] && source "$root/config/model.env"
[[ -f "$root/config/gateway.env" ]] && source "$root/config/gateway.env"
# Lokale Laufzeit-Secrets (auch FALLBACK_API_KEY) aus derselben Env-Datei wie
# die Quadlet sie zieht. Nur ins Gedächtnis laden, niemals ausgeben.
[[ -f "$HOME/.config/llm-infra/gateway.env" ]] && source "$HOME/.config/llm-infra/gateway.env"
: "${LITELLM_IMAGE:=ghcr.io/berriai/litellm:v1.101.0}"; : "${LITELLM_PORT:=4000}"; : "${PENNYROYAL_BASE_URL:=http://pennyroyal:8001/v1}"
install -d "$root/quadlet"
cat > "$root/quadlet/litellm.container" <<UNIT
# GENERIERT von scripts/60-install-gateway.sh - dort ändern, nicht hier.
[Unit]
Description=LiteLLM API gateway
After=pennyroyal.service
Wants=llm-inference-network.service
[Container]
Image=$LITELLM_IMAGE
ContainerName=litellm
Network=llm-inference.network
PublishPort=127.0.0.1:$LITELLM_PORT:4000
EnvironmentFile=%h/.config/llm-infra/gateway.env
Environment=LITELLM_CONFIG=/etc/litellm/config.yaml
# Kuerzt Python-Stacktraces im stdout-Log (LiteLLM v1.101 trunciert Logs ueber
# diese env-Variable; ohne sie blaest ein einziger Upstream-Fehler das Journal
# mit ~10 kB Traceback pro Request - siehe MAX_STRING_LENGTH_STDOUT_LOG in
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
cat > "$root/config/litellm.yaml" <<YAML
# Lokale automatische Kette qwen -> bonsai -> luna.
# Siemens-Modelle sind separat waehlbar fuer Reviews/Benchmarks, NICHT im Fallback:
# Direkte 512-Token-API-Probe, 08.10.2026, n=3: DeepSeek median 31.81s
# (16.24-72.13s), Siemens-Qwen median 20.11s (2.50-96.35s); hohe Varianz,
# daher nicht in den interaktiven automatischen Fallback aufnehmen.
# Schluessel: master/db aus ~/.config/llm-infra/gateway.env; FALLBACK_API_KEY
# ist ein Dummy, den der lokale llama-server nicht prueft; Luna braucht keinen
# Schluessel - das Geraet-Login legt das Token unter /etc/chatgpt-tokens ab.
# Fail-fast (Messung 2026-10-08 auf Test-Instanz, Primaer tot): Mit globalem
# num_retries=3 + OpenAI-SDK-max_retries kostete JEDE Anfrage ~22 s, weil bei nur
# einem Deployment pro Modellname nie ein Cooldown greift. Deshalb sind Retries
# fuer die lokalen Stufen (qwen, bonsai) AUS: Fehler -> sofort naechste Stufe
# (<1 s). Luna (letzte Stufe) behaelt die globalen Retries.
model_list:
  - model_name: qwen3.8-flash-next
    litellm_params:
      model: openai/pennyroyal
      api_base: ${PENNYROYAL_BASE_URL}
      api_key: "os.environ/LITELLM_MASTER_KEY"
      num_retries: 0
      max_retries: 0
      timeout: 600
  - model_name: bonsai-2-27b
    litellm_params:
      model: openai/bonsai-2-27b
      api_base: http://bonsai:8082/v1
      api_key: "os.environ/FALLBACK_API_KEY"
      num_retries: 0
      max_retries: 0
      timeout: 300
  - model_name: gpt-6-luna
    model_info:
      mode: responses
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
  fallbacks:
    - qwen3.8-flash-next: ["bonsai-2-27b", "gpt-6-luna"]
    - bonsai-2-27b: ["gpt-6-luna"]
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  database_url: "os.environ/DATABASE_URL"
YAML
log 'LiteLLM Quadlet and config generated.'
