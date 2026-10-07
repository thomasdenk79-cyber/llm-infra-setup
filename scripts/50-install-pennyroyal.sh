#!/usr/bin/env bash
# Generate the Pennyroyal (SGLang) Quadlet from configuration and pin the image
# by digest. This script never starts or restarts the runtime; use
# scripts/apply-runtime-unit.sh for that, which refuses to interrupt requests.
#
# Result: quadlet/pennyroyal.container (committed, generated - do not edit by hand)
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${PENNYROYAL_IMAGE:=ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
: "${PENNYROYAL_PORT:=8001}"
: "${LLM_MODELS_DIR:=${HOME}/models}"
: "${LLM_CACHE_DIR:=${HOME}/.local/share/llm-infra/cache}"
: "${LLM_NIXL_DIR:=${HOME}/.local/share/llm-infra/nixl}"
: "${PENNY_PLE_BACKEND:=ram}"
: "${MODEL_ID:=RadixArk/Qwen3.8-Flash-Next-NVFP4}"
: "${PENNY_PLE_NVME_MODEL:=${HOME}/.local/share/llm-infra/ple/Qwen3.8-Flash-Next-PLE-NVME}"
: "${PENNY_GPU_UUID:=GPU-780d3589-9811-40ec-db66-93a9146697f3}"
: "${PENNY_CDI_DEVICE:=nvidia.com/gpu=all}"
: "${PENNY_LOADER_THREADS:=4}"
: "${PENNY_BUILD_JOBS:=4}"
: "${PENNY_TORCH_COMPILE_THREADS:=4}"
: "${PENNY_OMP_THREADS:=4}"
# The SSD PLE reader uses io_uring.  Podman's default seccomp profile blocks the
# required io_uring setup syscall on this host, so keep this explicit. A tighter
# custom profile is tracked as an open item in docs/security.md.
: "${PENNY_SECURITY_OPT:=seccomp=unconfined}"
# Zero disables the host RAM HiCache tier; useful on 64-GB hosts where the model
# loader's temporary CPU peak leaves no reservation margin.
: "${PENNY_HICACHE_SIZE_GB:=8}"
: "${PENNY_HEALTH_START_SECONDS:=1800}"
# Online-FP8 fuer FP4-Pruefpunkte (MXFP8 fuer die noch in BF16 laufenden
# Projektionen; die NVFP4-Experten bleiben unberuehrt). Standert aus: der
# Upstream-Hinweis lautet "read the FP8 guide before switching this on".
# Achtung: der Wert fliest in die NIXL-Cache-Identitaet ein - beim Umschalten
# ist der Zeichenspeicher-Cache neu aufzubauen (erklaerung in docs/performance.md).
: "${PENNY_ONLINE_FP8:=false}"
case "${PENNY_ONLINE_FP8}" in true|false) : ;; *) log 'PENNY_ONLINE_FP8 muss true oder false sein.'; exit 1 ;; esac
# Aufnahmefaehigkeit der Laufzeit. Die Bild-Defaults sind MAX_RUNNING_REQUESTS=4 und
# MAX_MAMBA_CACHE_SIZE=24; beide sind hier uebersteuerbar (read request-capacity.sh
# im Bild: die Werte kommen als Umgebungsvariablen). Mehr aufgenommene Anfragen
# bedeuten hoeheren Gesamtdurchsatz, aber niedrigere Rate pro Anfrage und mehr
# Zustandsspeicher. Deshalb: aendern, messen, ggf. zurueck (apply-tuning.sh).
CAP_ENV=''
# a) Aufnahmefaehigkeit: das Bild liest diese Namen ohne PENNY_-Vorsatz
for name in MAX_RUNNING_REQUESTS MAX_MAMBA_CACHE_SIZE MAX_TOTAL_TOKENS; do
  value_var="PENNY_${name}"
  if [[ -n "${!value_var:-}" ]]; then
    CAP_ENV+="Environment=${name}=${!value_var}"$'\n'
  fi
done
# b) Werte, die unser Startskript selbst unter ihrem PENNY_-Namen liest
for name in PENNY_CUDA_GRAPH_MAX_BS PENNY_ENABLE_MEMORY_SAVER PENNY_USE_EXPANDABLE_SEGMENTS PENNY_MEM_FRACTION_STATIC; do
  if [[ -n "${!name:-}" ]]; then
    CAP_ENV+="Environment=${name}=${!name}"$'\n'
  fi
done
: "${PENNY_MODEL_NAME:=pennyroyal}"
: "${PENNYROYAL_EXTRA_ENV:=}"
have podman || { log 'FEHLT: podman. Jetzt ausführen: make install'; exit 1; }
for name in PENNY_LOADER_THREADS PENNY_BUILD_JOBS PENNY_TORCH_COMPILE_THREADS PENNY_OMP_THREADS; do
  [[ "${!name}" =~ ^[1-9][0-9]*$ ]] || { log "${name} muss positiv sein."; exit 1; }
done
retry podman pull "${PENNYROYAL_IMAGE}"
digest="$(podman image inspect "${PENNYROYAL_IMAGE}" --format '{{.Digest}}')"
[[ "${digest}" == sha256:* ]] || { log "Digest von ${PENNYROYAL_IMAGE} nicht ermittelbar."; exit 1; }
if [[ "${PENNYROYAL_IMAGE}" == *@* ]]; then
  image_ref="${PENNYROYAL_IMAGE}"
else
  image_ref="${PENNYROYAL_IMAGE}@${digest}"
fi
install -d -m 0755 "${root}/quadlet"

# Optional extra environment lines for documented tuning experiments.
extra_env=''
for pair in ${PENNYROYAL_EXTRA_ENV}; do
  extra_env+="Environment=${pair}"$'\n'
done

cat > "${root}/quadlet/pennyroyal.container" <<UNIT
# GENERIERT von scripts/50-install-pennyroyal.sh - bitte dort ändern, nicht hier.
# Änderung wirksam machen: ./scripts/apply-runtime-unit.sh
[Unit]
Description=Pennyroyal SGLang RTX PRO 6000 runtime
After=network-online.target
Wants=llm-inference-network.service

[Container]
Image=${image_ref}
ContainerName=pennyroyal
# The runtime stays single-homed on the inference network. Prometheus is attached
# to both networks and pulls /metrics from here; see docs/architecture.md.
Network=llm-inference.network
PublishPort=127.0.0.1:${PENNYROYAL_PORT}:8001
AddDevice=${PENNY_CDI_DEVICE}
PodmanArgs=--security-opt=${PENNY_SECURITY_OPT}
Volume=${LLM_MODELS_DIR}:/models:ro
Volume=${LLM_CACHE_DIR}/pennyroyal:/cache:U,Z
Volume=${LLM_NIXL_DIR}:/nixl:U,Z
Volume=$(dirname "${PENNY_PLE_NVME_MODEL}"):/ple:ro,Z
Volume=@CONFIG_ROOT@/config/pennyroyal/serve-flash-next-frspec.sh:/opt/pennyroyal/configs/pennyroyal/serve-flash-next-frspec.sh:ro,Z
Environment=HF_HOME=/cache/huggingface
Environment=TARGET_MODEL=/models/$(basename "${MODEL_ID}")
Environment=CACHE_BASE=/cache
Environment=NIXL_STORAGE_BASE=/nixl
Environment=CUDA_DEVICE_ORDER=PCI_BUS_ID
# WSL CUDA UUID masking survives index remapping after driver reconnects.
# SGLang sees only Blackwell at logical cuda:0; CDI supplies shared /dev/dxg.
Environment=CUDA_VISIBLE_DEVICES=${PENNY_GPU_UUID}
Environment=OMP_NUM_THREADS=${PENNY_OMP_THREADS}
Environment=MKL_NUM_THREADS=${PENNY_OMP_THREADS}
Environment=OPENBLAS_NUM_THREADS=${PENNY_OMP_THREADS}
Environment=NUMEXPR_NUM_THREADS=${PENNY_OMP_THREADS}
Environment=MAX_JOBS=${PENNY_BUILD_JOBS}
Environment=PENNY_BUILD_JOBS=${PENNY_BUILD_JOBS}
Environment=TORCHINDUCTOR_COMPILE_THREADS=${PENNY_TORCH_COMPILE_THREADS}
Environment=CMAKE_BUILD_PARALLEL_LEVEL=${PENNY_BUILD_JOBS}
Environment=CARGO_BUILD_JOBS=${PENNY_BUILD_JOBS}
Environment=FLASHINFER_NINJA_JOBS=${PENNY_BUILD_JOBS}
Environment=FLASHINFER_NVCC_THREADS=1
Environment=TORCH_HOME=/cache/torch
Environment=TORCHINDUCTOR_CACHE_DIR=/cache/torchinductor
Environment=TRITON_CACHE_DIR=/cache/triton
Environment=CUDA_CACHE_PATH=/cache/cuda
Environment=FLASHINFER_WORKSPACE_BASE=/cache/flashinfer
Environment=SGLANG_CACHE_DIR=/cache/sglang
Environment=SGLANG_JIT_CACHE_DIR=/cache/sglang/jit
Environment=PENNY_LOADER_THREADS=${PENNY_LOADER_THREADS}
Environment=PENNY_HICACHE_SIZE_GB=${PENNY_HICACHE_SIZE_GB}
Environment=PENNY_PLE_BACKEND=${PENNY_PLE_BACKEND}
Environment=SGLANG_SM120_ONLINE_MXFP8=${PENNY_ONLINE_FP8}
Environment=PENNY_PLE_NVME_MODEL=/ple/$(basename "${PENNY_PLE_NVME_MODEL}")
${extra_env}${CAP_ENV}# python3 exists in the runtime image; curl is not guaranteed.
HealthCmd=python3 -c "import sys,urllib.request;sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8001/health',timeout=8).status==200 else 1)"
HealthInterval=30s
HealthTimeout=15s
HealthRetries=4
HealthStartPeriod=${PENNY_HEALTH_START_SECONDS}s
Exec=next

[Service]
Restart=on-failure
RestartSec=30
# A live but hanging server is restarted by the external watchdog, because
# systemd cannot observe the Podman health state: scripts/runtime-watchdog.sh.
KillMode=mixed
TimeoutStopSec=180
TimeoutStartSec=3600

[Install]
WantedBy=default.target
UNIT
log "Pennyroyal-Unit erzeugt (Digest ${digest})."
log 'Noch NICHT aktiv: ./scripts/apply-runtime-unit.sh prüft zuerst laufende Anfragen.'
