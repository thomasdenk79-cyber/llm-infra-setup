#!/usr/bin/env bash
# Variante D: Turbo r24 + PR36567-Overlay mit Double-Buffer-Staging und mmap-/Page-Cache-PLE-Lesepfad.
# Baut ein eigenes Overlay-Bild (eigenes Tag) und eine Vergleichs-Unit auf
# Port 8005, veraendert weder den Produktionsdienst sglang-turbo-c6 noch
# Pennyroyal.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "$root/lib/common.sh"
[[ -f "$root/config/host.env" ]] && source "$root/config/host.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${LLM_CACHE_DIR:=/srv/llm/cache}"
: "${TURBO_SOURCE_DIR:=/srv/llm/cache/sglang-qwen38fn-sm120-turbo-r24}"
: "${TURBO_BASE_IMAGE:=localhost/sglang-qwen38fn-sm120-turbo:r24}"
: "${TURBO_IMAGE:=localhost/sglang-qwen38fn-sm120-turbo:r24-pr36567-variant-d}"
: "${TURBO_MODEL_DIR:=Qwen3.8-Flash-Next-NVFP4}"
: "${TURBO_VARIANT_D_PORT:=8005}"
: "${TURBO_VARIANT_D_CONTAINER_NAME:=sglang-turbo-variant-d}"
: "${TURBO_VARIANT_D_MMAP_CACHE_MB:=512}"
: "${TURBO_VARIANT_D_PREFETCH:=async}"

have podman || { log 'FEHLT: podman'; exit 1; }
[[ -d "$LLM_MODELS_DIR/$TURBO_MODEL_DIR" ]] || { log "Modell fehlt: $LLM_MODELS_DIR/$TURBO_MODEL_DIR"; exit 1; }
[[ -d "$TURBO_SOURCE_DIR/.git" ]] || { log "Turbo-Quelle fehlt: $TURBO_SOURCE_DIR (zuerst make turbo-c6-install)"; exit 1; }
[[ "$(git -C "$TURBO_SOURCE_DIR" rev-parse HEAD)" == c6cd5062669625fdbaf08032931f10b6661f8f6f ]] || { log 'Turbo-Revision ist nicht r24 c6cd506; Abbruch'; exit 1; }
[[ -n "$(podman image inspect "$TURBO_BASE_IMAGE" --format '{{.Id}}' 2>/dev/null)" ]] || { log "Basis-Image fehlt: $TURBO_BASE_IMAGE (zuerst make turbo-c6-install)"; exit 1; }

log "Baue Overlay-Image $TURBO_IMAGE aus config/turbo (Branch-Stand)"
podman build --pull=never --build-arg BASE_IMAGE="$TURBO_BASE_IMAGE" \
  -t "$TURBO_IMAGE" -f "$root/config/turbo/Dockerfile.pr36567" "$root/config/turbo"

unit="$root/quadlet/sglang-turbo-variant-d.container"
cat > "$unit" <<UNIT
# GENERIERT von scripts/54-install-sglang-turbo-variant-d.sh.
# Variante D: Double-Buffer-Staging + mmap Page-Cache, eigener Port.
[Unit]
Description=SGLang Turbo r24 Variante D (Double-Buffer-Staging, mmap PLE)
After=network-online.target
Wants=llm-inference-network.service

[Container]
Image=$TURBO_IMAGE
ContainerName=$TURBO_VARIANT_D_CONTAINER_NAME
Network=llm-inference.network
PublishPort=127.0.0.1:$TURBO_VARIANT_D_PORT:8001
AddDevice=nvidia.com/gpu=all
PodmanArgs=--ipc=host --security-opt=seccomp=$root/config/turbo/seccomp-io-uring.json
Volume=$LLM_MODELS_DIR:/models:ro
Volume=$LLM_CACHE_DIR/sglang-turbo:/cache:U,Z
Volume=$root/config/turbo/serve-qwen38-flash-next-c6-upstream-ple.sh:/opt/turbo/serve-c6.sh:ro,Z
Environment=TARGET_MODEL=/models/$TURBO_MODEL_DIR
Environment=SGLANG_QWEN4_PLE_NVME_PATH=/models/$TURBO_MODEL_DIR
Environment=SGLANG_QWEN4_PLE_NVME_BACKEND=mmap
Environment=SGLANG_QWEN4_PLE_NVME_MMAP_CACHE_MB=$TURBO_VARIANT_D_MMAP_CACHE_MB
Environment=SGLANG_QWEN4_PLE_NVME_PREFETCH=$TURBO_VARIANT_D_PREFETCH
Environment=SGLANG_RUST_BUILD_MODE=auto
Environment=RUSTUP_TOOLCHAIN=stable
Environment=RUSTUP_OFFLINE=1
Environment=SGLANG_PORT=8001
Environment=TURBO_CUDA_GRAPH=off
Environment=TURBO_CUDA_GRAPH_BACKEND_PREFILL=disabled
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
log "Variante-D-Unit erzeugt: $unit"
log 'Vor dem ersten Start: PLE in den Seitenspeicher vorladen - ./scripts/ple-preload.sh && ./scripts/ple-preload.sh --status'
log 'Naechster Schritt (explizit, GPU exclusiv): systemctl --user daemon-reload && systemctl --user start sglang-turbo-variant-d.service'
