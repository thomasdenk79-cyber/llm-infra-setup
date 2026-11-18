#!/usr/bin/env bash
# Erzeugt die cAdvisor-Unit: CPU- und Arbeitsspeicherkennzahlen je Container (Netz nur je Host - rootless).
#
#   Warum: ohne cAdvisor fehlen der Plattform-Seite die Ansichten "wer frisst
#   was" - Host-Kennzahlen alone zeigen nur das Gesamtbild.
#   Bildstand: pinned in versions.lock (cadvisor_image). Kein Datenvolume,
#   nichts beschreibbar, Port nur auf 127.0.0.1:9188 (Container intern 8080).
#
#   rootless-Hinweis: cAdvisor liest die Cgroup-Datei des Benutzers
#   (user.slice) - deshalb Cgroupns=host und --pid=host noetig. Die
#   Container erscheinen mit den Namen der systemd-Units (systemd-*).
#
# Danach: systemctl --user start llm-cadvisor.service
#         curl -s 127.0.0.1:9188/metrics | head     (erste Zeilen pruefen)
# Port 9188 statt 8080: 8080 und 8081 sind auf diesem Host belegt (Dozzle).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${CADVISOR_IMAGE:=ghcr.io/google/cadvisor:v0.61.0}"
install -d -m 0755 "${root}/quadlet"
cat > "${root}/quadlet/llm-cadvisor.container" <<UNIT
# GENERIERT von scripts/66-install-cadvisor.sh.
[Unit]
Description=cAdvisor (Container-Kennzahlen)
After=llm-observability-network.service

[Container]
Image=${CADVISOR_IMAGE}
ContainerName=llm-cadvisor
Network=llm-observability.network
PublishPort=127.0.0.1:9188:8080
Volume=/sys/fs/cgroup:/sys/fs/cgroup:ro
PodmanArgs=--pid=host --cgroupns=host --security-opt label=disable
Exec=--housekeeping_interval=15s --docker_only=false --store_container_labels=false

[Service]
Restart=on-failure
RestartSec=15

[Install]
WantedBy=default.target
UNIT
log 'cAdvisor-Unit erzeugt (Port 127.0.0.1:9188, read-only Cgroup-Blick).'
