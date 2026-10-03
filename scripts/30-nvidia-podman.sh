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
retry systemctl --user enable --now podman.socket
if ! sudo loginctl enable-linger "${USER}"; then
  log 'WARNUNG: linger konnte nicht gesetzt werden. Ohne linger starten die User-Dienste'
  log '         nicht nach einem Neustart. Manuell: sudo loginctl enable-linger '"${USER}"
fi
if have nvidia-ctk && nvidia-smi -L >/dev/null 2>&1; then
  # Die Datei enthaelt die aktuelle PCI-Adresse und Taktliste; nach Hardware- oder
  # Treiberaenderungen muss sie neu erzeugt werden, sonst sehen Container die GPU nicht.
  sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
  nvidia-ctk cdi list
else
  log 'Kein NVIDIA-Werkzeug oder keine GPU sichtbar; CDI-Erzeugung verschoben.'
  log 'Nach GPU-Anschluss und Neustart erneut ausführen: make podman'
  exit 0
fi
podman info --format '{{.Host.OCIRuntime.Name}}' || true
if have nvidia-ctk && nvidia-ctk cdi list | grep -q 'nvidia.com/gpu'; then
  gpu_test_image='docker.io/nvidia/cuda:12.8.1-base-ubuntu24.04'
  if ! podman image exists "${gpu_test_image}"; then
    retry podman pull "${gpu_test_image}" || { log 'WARNUNG: Testimage nicht ladbar; GPU-Test übersprungen.'; exit 0; }
  fi
  retry podman run --rm --device nvidia.com/gpu=all "${gpu_test_image}" nvidia-smi -L
  log 'GPU ist in einem rootless Container sichtbar.'
else
  log 'WARNUNG: CDI-Gerät nvidia.com/gpu nicht gefunden.'
  log '         Prüfung: sudo nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml'
  exit 1
fi
