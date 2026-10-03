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
install -d -m 0755 "${root}/quadlet"
case "${GPU_EXPORTER}" in
  nvidia-smi)
    : "${GPU_EXPORTER_IMAGE:=docker.io/utkuozdemir/nvidia_gpu_exporter:1.4.0}"
    cat > "${root}/quadlet/llm-gpu-exporter.container" <<UNIT
# GENERIERT von scripts/65-install-gpu-exporter.sh (GPU_EXPORTER=nvidia-smi).
[Unit]
Description=NVIDIA GPU exporter (nvidia-smi)
After=llm-observability-network.service

[Container]
Image=${GPU_EXPORTER_IMAGE}
ContainerName=llm-gpu-exporter
Network=llm-observability.network
PublishPort=127.0.0.1:9835:9835
AddDevice=nvidia.com/gpu=all
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
    cat > "${root}/quadlet/llm-gpu-exporter.container" <<UNIT
# GENERIERT von scripts/65-install-gpu-exporter.sh (GPU_EXPORTER=dcgm).
[Unit]
Description=NVIDIA DCGM exporter
After=llm-observability-network.service

[Container]
Image=${GPU_EXPORTER_IMAGE}
ContainerName=llm-gpu-exporter
Network=llm-observability.network
PublishPort=127.0.0.1:9400:9400
AddDevice=nvidia.com/gpu=all
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
