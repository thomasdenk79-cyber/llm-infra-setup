#!/usr/bin/env bash
# Erzeugt einen isolierten Vergleichsdienst: unveraendertes Turbo-r24-Rezept
# plus PR36567 SSD-PLE-Reader mit io_uring und aktiven CUDA-Graphs.
# Der Dienst nutzt Port 8003 und veraendert turbo-c6 oder Pennyroyal nicht.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${LLM_CACHE_DIR:=/srv/llm/cache}"
: "${TURBO_SOURCE_DIR:=/srv/llm/cache/sglang-qwen38fn-sm120-turbo-r24}"
: "${TURBO_BASE_IMAGE:=localhost/sglang-qwen38fn-sm120-turbo:r24}"
: "${TURBO_IMAGE:=localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567-variant-a}"
: "${TURBO_MODEL_DIR:=Qwen3.8-Flash-Next-NVFP4}"
: "${TURBO_UPSTREAM_PORT:=8003}"
: "${TURBO_UPSTREAM_CONTAINER_NAME:=sglang-turbo-upstream-ple}"

have podman || { log 'FEHLT: podman'; exit 1; }
[[ -d "$LLM_MODELS_DIR/$TURBO_MODEL_DIR" ]] || { log "Modell fehlt: $LLM_MODELS_DIR/$TURBO_MODEL_DIR"; exit 1; }
[[ -d "$TURBO_SOURCE_DIR/.git" ]] || { log "Turbo-Quelle fehlt: $TURBO_SOURCE_DIR (zuerst make turbo-c6-install)"; exit 1; }
[[ "$(git -C "$TURBO_SOURCE_DIR" rev-parse HEAD)" == c6cd5062669625fdbaf08032931f10b6661f8f6f ]] || { log 'Turbo-Revision ist nicht r24 c6cd506; Abbruch'; exit 1; }
[[ -n "$(podman image inspect "$TURBO_BASE_IMAGE" --format '{{.Id}}' 2>/dev/null)" ]] || { log "Basis-Image fehlt: $TURBO_BASE_IMAGE (zuerst make turbo-c6-install)"; exit 1; }

# Das Overlay-Image wird immer aus dem Branch-Baum gebaut (Layer-Cache macht den
# Wiederholungslauf billig). Eigenes Tag: das Produktionsbild r24-pr36567 bleibt
# davon unangetastet.
log "Baue Overlay-Image $TURBO_IMAGE aus config/turbo (Branch-Stand)"
podman build --pull=never --build-arg BASE_IMAGE="$TURBO_BASE_IMAGE" \
  -t "$TURBO_IMAGE" -f "$root/config/turbo/Dockerfile.pr36567" "$root/config/turbo"

unit="$root/quadlet/sglang-turbo-upstream-ple.container"
cat > "$unit" <<UNIT
# GENERIERT von scripts/52-install-sglang-turbo-upstream-ple.sh.
# Vergleichsdienst: Port 8003, keine Aenderung am Produktionsdienst.
[Unit]
Description=SGLang Turbo r24 upstream recipe with SSD PLE comparison
After=network-online.target
Wants=llm-inference-network.service

[Container]
Image=$TURBO_IMAGE
ContainerName=$TURBO_UPSTREAM_CONTAINER_NAME
Network=llm-inference.network
PublishPort=127.0.0.1:$TURBO_UPSTREAM_PORT:8001
AddDevice=nvidia.com/gpu=all
PodmanArgs=--ipc=host --security-opt=seccomp=$root/config/turbo/seccomp-io-uring.json
Volume=$LLM_MODELS_DIR:/models:ro
Volume=$LLM_CACHE_DIR/sglang-turbo:/cache:U,Z
Volume=$root/config/turbo/serve-qwen38-flash-next-c6-upstream-ple.sh:/opt/turbo/serve-c6.sh:ro,Z
Environment=TARGET_MODEL=/models/$TURBO_MODEL_DIR
Environment=SGLANG_QWEN4_PLE_NVME_PATH=/models/$TURBO_MODEL_DIR
Environment=SGLANG_QWEN4_PLE_NVME_BACKEND=io_uring
Environment=SGLANG_QWEN4_PLE_NVME_CACHE_PAGES=0
Environment=SGLANG_RUST_BUILD_MODE=auto
Environment=RUSTUP_TOOLCHAIN=stable
Environment=RUSTUP_OFFLINE=1
Environment=SGLANG_PORT=8001
Environment=SGLANG_SM120_ONLINE_MXFP8=true
Environment=SGLANG_MM_PREPROCESS_DEVICE=cpu
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
log "Vergleichs-Unit erzeugt: $unit"
log 'Naechster Schritt (explizit, startet nur den Vergleichsdienst): systemctl --user daemon-reload && systemctl --user start sglang-turbo-upstream-ple.service'
