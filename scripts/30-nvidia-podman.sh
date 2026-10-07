#!/usr/bin/env bash
# Rootless Podman fuer GPU-Betrieb vorbereiten: Socket, Linger, CDI, Funktionstest.
#
#   ./scripts/30-nvidia-podman.sh
#
# Nach einem Neustart oder nach dem An-/Abstecken einer eGPU einfach erneut
# ausfuehren: Die CDI-Gerätedefinition wird dabei neu erzeugt.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
have podman || { log 'podman fehlt. Jetzt ausführen: make install'; exit 1; }
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNY_GPU_UUID:=GPU-780d3589-9811-40ec-db66-93a9146697f3}"
: "${PENNY_CDI_DEVICE:=nvidia.com/gpu=all}"
retry systemctl --user enable --now podman.socket
if ! sudo loginctl enable-linger "${USER}"; then
  log 'WARNUNG: linger konnte nicht gesetzt werden. Ohne linger starten die User-Dienste'
  log '         nicht nach einem Neustart. Manuell: sudo loginctl enable-linger '"${USER}"
fi
if have nvidia-ctk && nvidia-smi -L >/dev/null 2>&1; then
  # WSL exposes a shared /dev/dxg node through CDI. CUDA_VISIBLE_DEVICES is
  # restricted to the stable Blackwell UUID in the runtime and probe.
  sudo nvidia-ctk cdi generate --mode=wsl --output=/etc/cdi/nvidia.yaml
  sudo nvidia-ctk cdi list
  nvidia-smi --query-gpu=uuid --format=csv,noheader | grep -Fxq "${PENNY_GPU_UUID}" \
    || { log "GPU-UUID ${PENNY_GPU_UUID} ist laut nvidia-smi nicht sichtbar."; exit 1; }
else
  log 'Kein NVIDIA-Werkzeug oder keine GPU sichtbar; CDI-Erzeugung verschoben.'
  log 'Nach GPU-Anschluss und Neustart erneut ausführen: make podman'
  exit 0
fi
podman info --format '{{.Host.OCIRuntime.Name}}' || true
if have nvidia-ctk && nvidia-ctk cdi list | grep -q 'nvidia.com/gpu=all'; then
  gpu_test_image='docker.io/nvidia/cuda:12.8.1-base-ubuntu24.04'
  if ! podman image exists "${gpu_test_image}"; then
    retry podman pull "${gpu_test_image}" || { log 'WARNUNG: Testimage nicht ladbar; GPU-Test übersprungen.'; exit 0; }
  fi
  retry podman run --rm --device "${PENNY_CDI_DEVICE}" "${gpu_test_image}" nvidia-smi -L
  retry podman run --rm --device "${PENNY_CDI_DEVICE}" \
    -e CUDA_DEVICE_ORDER=PCI_BUS_ID -e CUDA_VISIBLE_DEVICES="${PENNY_GPU_UUID}" \
    --entrypoint python3 ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3 \
    -c 'import torch,torch.distributed as d; assert torch.cuda.device_count()==1; assert "Blackwell" in torch.cuda.get_device_name(0); torch.cuda.set_device(0); d.init_process_group(backend="nccl",rank=0,world_size=1); torch.ones(1,device="cuda:0"); print(torch.cuda.get_device_name(0))'
  log 'Pennyroyal-Container sieht ausschließlich die RTX PRO 6000 Blackwell.'
else
  log 'WARNUNG: CDI-Gerät nvidia.com/gpu nicht gefunden.'
  log '         Prüfung: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml'
  exit 1
fi
