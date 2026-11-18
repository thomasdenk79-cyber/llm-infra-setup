#!/usr/bin/env bash
# Generate the GPU metrics exporter unit.
#
#   GPU_EXPORTER=nvidia-smi   default, low risk, uses nvidia-smi read-only
#   GPU_EXPORTER=dcgm         richer metrics (DCGM field groups); start it only
#                             after a baseline run, because profiling fields can
#                             add overhead to a running inference container
#
# Danach: ./scripts/apply-runtime-unit.sh --dry-run  (zeigt Unterschiede zum Laeufer)
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${GPU_EXPORTER:=nvidia-smi}"
: "${GPU_CDI_DEVICE:=nvidia.com/gpu=all}"
# Bildreferenz kommt aus versions.lock (einzige Quelle der Wahrheit); Digest-Pin
# nur fuer das nvidia-smi-Bild, dcgm haengt an einem anderen Bestand.
lock_feld() { awk -F': ' -v f="$1" '$1==f{gsub(/ /,"",$2); print $2; exit}' "${root}/versions.lock" 2>/dev/null || true; }
: "${GPU_EXPORTER_IMAGE:=$(lock_feld nvidia_gpu_exporter_image)}"
[[ -z "${GPU_EXPORTER_IMAGE}" ]] && GPU_EXPORTER_IMAGE=docker.io/utkuozdemir/nvidia_gpu_exporter:1.4.0
if [[ "${GPU_EXPORTER}" == nvidia-smi && "${GPU_EXPORTER_IMAGE}" != *"@sha256:"* ]]; then
  gpu_digest="$(lock_feld nvidia_gpu_exporter_image_digest)"
  [[ -n "${gpu_digest}" ]] && GPU_EXPORTER_IMAGE="${GPU_EXPORTER_IMAGE}@${gpu_digest}"
fi
pruefung=0
[[ "${1:-}" == "--check" ]] && pruefung=1
ziel="${root}/quadlet/llm-gpu-exporter.container"
(( pruefung )) && ziel="$(mktemp)"
install -d -m 0755 "${root}/quadlet"
case "${GPU_EXPORTER}" in
  nvidia-smi)
    : "${GPU_EXPORTER_IMAGE:=docker.io/utkuozdemir/nvidia_gpu_exporter:1.4.0}"
    cat > "${ziel}" <<UNIT
# GENERIERT von scripts/65-install-gpu-exporter.sh (GPU_EXPORTER=nvidia-smi).
[Unit]
Description=NVIDIA GPU exporter (nvidia-smi)
After=llm-observability-network.service

[Container]
Image=${GPU_EXPORTER_IMAGE}
ContainerName=llm-gpu-exporter
Network=llm-observability.network
PublishPort=127.0.0.1:9835:9835
AddDevice=${GPU_CDI_DEVICE}
Exec=--web.listen-address=0.0.0.0:9835

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
    log 'GPU-Exporter-Unit erzeugt (nvidia-smi, Port 127.0.0.1:9835).'
    ;;
  dcgm)
    : "${GPU_EXPORTER_IMAGE:=docker.io/nvcr.io/nvidia/k8s/dcgm-exporter:3.3.9-3.4.1-ubuntu22.04}"
    cat > "${ziel}" <<UNIT
# GENERIERT von scripts/65-install-gpu-exporter.sh (GPU_EXPORTER=dcgm).
[Unit]
Description=NVIDIA DCGM exporter
After=llm-observability-network.service

[Container]
Image=${GPU_EXPORTER_IMAGE}
ContainerName=llm-gpu-exporter
Network=llm-observability.network
PublishPort=127.0.0.1:9400:9400
AddDevice=${GPU_CDI_DEVICE}
PodmanArgs=--pid=host --cap-add SYS_ADMIN
Exec=-a

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
    log 'DCGM-Exporter-Unit erzeugt (Port 127.0.0.1:9400).'
    log 'Hinweis: DCGM kann bei laufender Inferenz Messüberhead erzeugen - erst nach der Baseline aktivieren.'
    ;;
  *)
    log 'GPU_EXPORTER muss nvidia-smi oder dcgm sein.'
    exit 2
    ;;
esac

if (( pruefung )); then
  if diff -u "${root}/quadlet/llm-gpu-exporter.container" "${ziel}" >/tmp/gpu-exporter-check.diff 2>&1; then
    rm -f "${ziel}"; log 'Unit entspricht dem Generator'; exit 0
  fi
  rm -f "${ziel}"; echo 'DIFFERENZ - siehe /tmp/gpu-exporter-check.diff' >&2; exit 1
fi
