#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
[[ -f "$root/config/model.env" ]] && source "$root/config/model.env"
[[ -f "$root/config/gateway.env" ]] && source "$root/config/gateway.env"
: "${LITELLM_IMAGE:=ghcr.io/berriai/litellm:v1.101.0}"; : "${LITELLM_PORT:=4000}"; : "${PENNYROYAL_BASE_URL:=http://pennyroyal:8001/v1}"
# Optionaler Failover unter demselben model_name: nur wenn FALLBACK_LITELLM_MODEL
# und FALLBACK_API_KEY beide gesetzt sind, landet ein zweiter Deployment-Eintrag
# in der YAML; der Schluesselwert selbst wird nie hineingeschrieben (os.environ).
: "${FALLBACK_LITELLM_MODEL:=}"; : "${FALLBACK_API_BASE:=}"; : "${FALLBACK_API_KEY:=}"
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
Volume=@CONFIG_ROOT@/config/litellm.yaml:/etc/litellm/config.yaml:ro,Z
Exec=--config /etc/litellm/config.yaml --port 4000 --host 0.0.0.0
[Service]
Restart=on-failure
RestartSec=15
[Install]
WantedBy=default.target
UNIT
install -d "$root/config"
# Zweiter model_list-Eintrag nur bei vollstaendig gesetztem Fallback-Paar;
# sonst exakt die bisherige Einzeld-Deployment-Konfiguration (kein
# Verhaltenswechsel, wenn die Variablen leer bleiben).
fallback_yaml=""
if [[ -n "${FALLBACK_LITELLM_MODEL}" && -n "${FALLBACK_API_KEY}" ]]; then
  fallback_yaml="  - model_name: qwen3.8-flash-next
    litellm_params:
      model: ${FALLBACK_LITELLM_MODEL}
      api_key: \"os.environ/FALLBACK_API_KEY\"
"
  [[ -n "${FALLBACK_API_BASE}" ]] && fallback_yaml="${fallback_yaml}      api_base: ${FALLBACK_API_BASE}
"
fi
cat > "$root/config/litellm.yaml" <<YAML
model_list:
  - model_name: qwen3.8-flash-next
    litellm_params:
      model: openai/pennyroyal
      api_base: ${PENNYROYAL_BASE_URL}
      api_key: "os.environ/LITELLM_MASTER_KEY"
${fallback_yaml}router_settings:
  # Gegen LiteLLM v1.101.0 validiert: retry_interval existiert dort NICHT,
  # retry_after ist der Mindestabstand vor jedem Retry (Backoff beginnt hier).
  # num_retries 10 uebersteht kurze Pennyroyal-Neustarts ohne Client-500;
  # ein hohes allowed_fails verhindert, dass der einzige Upstream in Cooldown
  # faellt (Clients sahen sonst sofort 503 statt Retry-Arbeit). cooldown_time
  # bleibt kurz, damit ein echter Ausfall trotzdem schnell markiert wird.
  num_retries: 10
  retry_after: 10
  allowed_fails: 1000
  cooldown_time: 5
general_settings:
  master_key: "os.environ/LITELLM_MASTER_KEY"
  database_url: "os.environ/DATABASE_URL"
YAML
log 'LiteLLM Quadlet and config generated.'
