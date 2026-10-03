#!/usr/bin/env bash
# Baut und installiert den separaten Turbo-C6-Dienst. Pennyroyal wird weder
# ersetzt noch neu gestartet. Der Upstream-Stand ist per Commit festgenagelt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${LLM_CACHE_DIR:=/srv/llm/cache}"
: "${LLM_PLE_DIR:=/srv/llm/ple-native/Qwen3.8-Flash-Next-PLE-NVME}"
: "${TURBO_SOURCE_DIR:=/srv/llm/cache/sglang-qwen38fn-sm120-turbo-r24}"
: "${TURBO_IMAGE:=localhost/sglang-qwen38fn-sm120-turbo:r24-nvme}"
: "${TURBO_REVISION:=c6cd5062669625fdbaf08032931f10b6661f8f6f}"
: "${TURBO_PORT:=8002}"
: "${TURBO_CONTAINER_NAME:=sglang-turbo-c6}"
: "${TURBO_MODEL_DIR:=Qwen3.8-Flash-Next-NVFP4}"

have git || { log 'FEHLT: git'; exit 1; }
have podman || { log 'FEHLT: podman'; exit 1; }
[[ -d "$LLM_MODELS_DIR/$TURBO_MODEL_DIR" ]] || { log "Modell fehlt: $LLM_MODELS_DIR/$TURBO_MODEL_DIR"; exit 1; }
[[ -f "$LLM_PLE_DIR/model.safetensors.index.json" ]] || { log "NVMe-PLE-Overlay fehlt: $LLM_PLE_DIR (make ple-nvme)"; exit 1; }
install -d -m 0755 "$LLM_CACHE_DIR/sglang-turbo"

if [[ ! -d "$TURBO_SOURCE_DIR/.git" ]]; then
  install -d -m 0755 "$(dirname "$TURBO_SOURCE_DIR")"
  git clone https://github.com/mratsim/sglang-qwen38fn-sm120-turbo.git "$TURBO_SOURCE_DIR"
fi
git -C "$TURBO_SOURCE_DIR" fetch --quiet --depth 1 origin master
actual="$(git -C "$TURBO_SOURCE_DIR" rev-parse HEAD)"
if [[ "$actual" != "$TURBO_REVISION" ]]; then
  git -C "$TURBO_SOURCE_DIR" checkout --detach --quiet "$TURBO_REVISION"
fi
[[ "$(git -C "$TURBO_SOURCE_DIR" rev-parse HEAD)" == "$TURBO_REVISION" ]] || { log 'Turbo-Revision stimmt nicht'; exit 1; }

log "Baue $TURBO_IMAGE aus Turbo-Revision $TURBO_REVISION"
podman build --pull=missing -t "$TURBO_IMAGE" "$TURBO_SOURCE_DIR"
log "Baue NVMe-SSD-Stream-Overlay aus dem versionierten Adapter"
podman build --pull=never -f "$root/config/turbo/Dockerfile.ssd" -t "$TURBO_IMAGE" "$root"
digest="$(podman image inspect "$TURBO_IMAGE" --format '{{.Id}}')"
[[ -n "$digest" ]] || { log 'Turbo-Image konnte nicht inspiziert werden'; exit 1; }

install -d -m 0755 "$root/quadlet"
cat > "$root/quadlet/sglang-turbo-c6.container" <<UNIT
# GENERIERT von scripts/51-install-sglang-turbo.sh - bitte dort aendern.
[Unit]
Description=SGLang SM120 Turbo C6 production runtime (separate Penny fallback)
After=network-online.target
Wants=llm-inference-network.service

[Container]
Image=$TURBO_IMAGE
ContainerName=$TURBO_CONTAINER_NAME
Network=llm-inference.network
PublishPort=127.0.0.1:$TURBO_PORT:8001
AddDevice=nvidia.com/gpu=all
PodmanArgs=--ipc=host --security-opt=seccomp=unconfined
Volume=$LLM_MODELS_DIR:/models:ro
Volume=$LLM_CACHE_DIR/sglang-turbo:/cache:U,Z
Volume=$LLM_PLE_DIR:/ple-table:ro,Z
Volume=@CONFIG_ROOT@/config/turbo/serve-qwen38-flash-next-c6.sh:/opt/turbo/serve-c6.sh:ro,Z
Environment=TARGET_MODEL=/models/$TURBO_MODEL_DIR
Environment=PLE_DIR=/ple-table
Environment=SGLANG_PORT=8001
Environment=SGLANG_SM120_ONLINE_MXFP8=true
Environment=SGLANG_MM_PREPROCESS_DEVICE=cpu
Environment=PENNY_PLE_BACKEND=nvme
Environment=SGLANG_PLUGINS=ssd_stream
Environment=SGLANG_SSD_STREAM_MANIFEST=/ple-table/ssd-stream.json
Environment=PYTHONPATH=/opt/sglang-ssd-stream/src
Environment=MAX_RUNNING_REQUESTS=6
Environment=MAX_MAMBA_CACHE_SIZE=27
Environment=MAX_TOTAL_TOKENS=1048576
Environment=HICACHE_SIZE_GB=8
Environment=MEM_FRACTION_STATIC=0.98
Environment=HF_HOME=/cache/huggingface
HealthCmd=python3 -c "import sys,urllib.request;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health',timeout=8).status==200 else 1)"
HealthInterval=30s
HealthTimeout=15s
HealthRetries=4
HealthStartPeriod=2400s
Exec=/opt/turbo/serve-c6.sh

[Service]
Restart=on-failure
RestartSec=30
KillMode=mixed
TimeoutStartSec=3600
TimeoutStopSec=180

[Install]
WantedBy=default.target
UNIT
sed -i "s|@CONFIG_ROOT@|$root|g" "$root/quadlet/sglang-turbo-c6.container"
log "Turbo-Unit erzeugt: quadlet/sglang-turbo-c6.container"
log "Naechster Schritt: ./scripts/apply-turbo-c6.sh"
