#!/usr/bin/env bash
# Host-Kennzahlen fuer Prometheus erzeugen (Textfile-Collector des node_exporter).
#
# Warum ein eigenes Skript? Prometheus kommt von rootless Podman aus nicht an die
# Loopback-Ports des Hosts. Alles, was nur der Host selbst messen kann (ZFS-Status,
# NVMe-Werte, PCIe-Anbindung der GPU, Zustand der User-Dienste, letzter Benchmark),
# wird hier als Textdatei abgelegt und vom node_exporter eingesammelt.
#
#   ./scripts/collect-host-facts.sh                 eine Sammlung, atomar geschrieben
#   ./scripts/collect-host-facts.sh --pruefen       gleiche Ausgabe, ohne zu schreiben
#
# Automatisch alle 30 s nach `make collector`.
# Das Skript ist zerstoerungsfrei; einzelne Teilbereiche duerfen scheitern.
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=common.sh
source "${root}/lib/common.sh"
# shellcheck source=units.sh
source "${root}/lib/units.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${PLE_STORAGE_IMAGE:=/srv/llm/ple-nvme.ext4}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
# Kanonische Ansprache der Laufzeit (Host, Port, Container, Unit, Image).
# config/host.env ist vorher eingelesen und bestimmt deshalb die Werte.
runtime_identity
TEXTFILE_DIR="${LLM_NODE_EXPORTER_TEXTFILE:-${HOME}/.local/share/llm-infra/node-exporter/textfile}"
MODEL_ID="${MODEL_ID:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
dry_run=0
[[ "${1:-}" == "--pruefen" ]] && dry_run=1

raw="$(mktemp)"
tmp="$(mktemp)"
trap 'rm -f "${raw}" "${tmp}"' EXIT

# emit <messwert>  - eine Zeile im Stil "name{label=\"wert\"} 1"
emit() { printf '%s\n' "$1" >> "${raw}"; }

# --- User-Dienste -----------------------------------------------------------
# Die Listen kommen aus lib/units.sh (INFERENCE_UNITS, OBSERVABILITY_UNITS,
# HOST_UNITS, MONITOR_TIMERS) und werden um MONITOR_EXTRA_UNITS bzw.
# MONITOR_EXTRA_TIMERS aus config/host.env ergaenzt - Rechnerfremde Dienste
# stehen also in der Rechnerkonfiguration, nicht hier.
#
# Eine Messreihe liefert nur, wer auf diesem Rechner wirklich existiert
# (unit_exists aus lib/units.sh): eine nicht installierte Einheit - hier
# pennyroyal.service, weil die Laufzeit ein Container ist - hat keinen Zustand,
# den man melden koennte; eine Null waere eine Aussage ueber etwas, das es nicht
# gibt. Vorhandene, aber stehende Einheiten behalten ihre 0; darauf haengen die
# Alarme in alerts.yml.
emit_unit_active() {
  # emit_unit_active <service-name> <label-name>
  local state
  if systemctl --user is-active --quiet "$1" 2>/dev/null; then state=1; else state=0; fi
  emit "llm_unit_active{unit=\"${2}\"} ${state}"
}

if have systemctl; then
  declare -A seen_unit=() seen_timer=()
  extra_units=() extra_timers=()
  read -r -a extra_units <<< "${MONITOR_EXTRA_UNITS:-}"
  read -r -a extra_timers <<< "${MONITOR_EXTRA_TIMERS:-}"

  for spec in "${INFERENCE_UNITS[@]}" "${OBSERVABILITY_UNITS[@]}"; do
    svc="$(unit_service_name "${spec}")"
    unit="${svc%.service}"
    [[ -n "${seen_unit[${unit}]:-}" ]] && continue
    unit_exists "${svc}" || continue
    seen_unit["${unit}"]=1
    emit_unit_active "${svc}" "${unit}"
  done
  for unit in "${HOST_UNITS[@]}" "${extra_units[@]}"; do
    [[ -n "${seen_unit[${unit}]:-}" ]] && continue
    unit_exists "${unit}.service" || continue
    seen_unit["${unit}"]=1
    emit_unit_active "${unit}.service" "${unit}"
  done
  for timer in "${MONITOR_TIMERS[@]}" "${extra_timers[@]}"; do
    [[ -n "${seen_timer[${timer}]:-}" ]] && continue
    unit_exists "${timer}.timer" || continue
    seen_timer["${timer}"]=1
    if systemctl --user is-active --quiet "${timer}.timer" 2>/dev/null; then state=1; else state=0; fi
    emit "llm_timer_active{timer=\"${timer}\"} ${state}"
  done
fi

# --- Laufzeit der Runtime ---------------------------------------------------
# Betriebszeit der Laufzeit: bei einer eigenen Unit antwortet systemd, sonst
# steht der Startzeitpunkt im Container (vLLM laeuft auf diesem Rechner ohne
# Quadlet-Unit). Kein Messwert, wenn die Laufzeit nicht laeuft - eine 0 waere
# eine Betriebszeit, die nie begonnen haette.
runtime_uptime_seconds() {
  # runtime_uptime_seconds <startzeittext> -> Sekunden seit Start, sonst leer.
  # Beide Formate, die hier vorkommen:
  #   systemd: "Mon 2026-11-16 02:54:10 CET"        podman: "2026-11-16 02:54:10.148 +0100 CET"
  DATE_VALUE="${1:-}" python3 -c '
import datetime, os, re
raw = os.environ["DATE_VALUE"].strip()
if not raw:
    raise SystemExit(0)
now = datetime.datetime.now(datetime.timezone.utc)
match = re.search(r"(\d{4}-\d{2}-\d{2})[T ](\d{2}:\d{2}:\d{2})(?:\.\d+)?(?:\s*(Z|[+-]\d{2}:?\d{2}))?", raw)
if not match:
    raise SystemExit(0)
date_, time_, offset = match.groups()
offset = (offset or "").replace(":", "")
if offset == "Z":
    offset = "+0000"
if offset:
    started = datetime.datetime.strptime("%s %s%s" % (date_, time_, offset), "%Y-%m-%d %H:%M:%S%z")
else:
    started = datetime.datetime.strptime("%s %s" % (date_, time_), "%Y-%m-%d %H:%M:%S")
    started = started.replace(tzinfo=now.astimezone().tzinfo)
print(max(0, int((now - started).total_seconds())))
' 2>/dev/null
}

uptime_seconds=''
if runtime_is_running; then
  if [[ -n "${RUNTIME_SERVICE}" ]] && systemctl --user is-active --quiet "${RUNTIME_SERVICE}" 2>/dev/null; then
    start_raw="$(systemctl --user show "${RUNTIME_SERVICE}" -p ExecMainStartTimestamp --value 2>/dev/null || true)"
  else
    start_raw="$(podman inspect "${RUNTIME_CONTAINER}" -f '{{.State.StartedAt}}' 2>/dev/null || true)"
  fi
  uptime_seconds="$(runtime_uptime_seconds "${start_raw}")"
fi
[[ -n "${uptime_seconds}" ]] && emit "llm_runtime_uptime_seconds ${uptime_seconds}"

# --- ZFS --------------------------------------------------------------------
if have zpool && have zfs; then
  while read -r pool health; do
    [[ -n "${pool}" ]] || continue
    case "${health}" in
      ONLINE) code=1 ;; DEGRADED) code=2 ;; FAULTED) code=3 ;; *) code=0 ;;
    esac
    emit "llm_zfs_pool_health{pool=\"${pool}\"} ${code}"
    if zpool status "${pool}" 2>/dev/null | grep -q 'scan.*in progress'; then
      emit "llm_zfs_scrub_running{pool=\"${pool}\"} 1"
    else
      emit "llm_zfs_scrub_running{pool=\"${pool}\"} 0"
    fi
  done < <(zpool list -H -o name,health 2>/dev/null)

  while read -r name mount used avail ratio; do
    [[ "${mount}" == "-" || -z "${name}" ]] && continue
    emit "llm_zfs_dataset_used_bytes{dataset=\"${name}\",mountpoint=\"${mount}\"} ${used}"
    emit "llm_zfs_dataset_avail_bytes{dataset=\"${name}\",mountpoint=\"${mount}\"} ${avail}"
    emit "llm_zfs_dataset_compress_ratio{dataset=\"${name}\"} ${ratio%x}"
  done < <(zfs list -H -p -o name,mountpoint,used,avail,compressratio 2>/dev/null)

  if [[ -r /proc/spl/kstat/zfs/arcstats ]]; then
    arc="$(awk '/^size[[:space:]]/ {print $3}' /proc/spl/kstat/zfs/arcstats)"
    hits="$(awk '/^hits[[:space:]]/ {print $3}' /proc/spl/kstat/zfs/arcstats)"
    misses="$(awk '/^misses[[:space:]]/ {print $3}' /proc/spl/kstat/zfs/arcstats)"
    [[ -n "${arc}" ]] && emit "llm_zfs_arc_bytes ${arc}"
    [[ -n "${hits}" && -n "${misses}" ]] && emit "llm_zfs_arc_hits ${hits}" && emit "llm_zfs_arc_misses ${misses}"
  fi
fi

# --- PCIe-Anbindung der GPU -------------------------------------------------
for d in /sys/bus/pci/devices/*; do
  [[ -f "${d}/vendor" ]] || continue
  grep -q 0x10de "${d}/vendor" 2>/dev/null || continue
  bus="$(basename "${d}")"
  cur_w="$(cat "${d}/current_link_width" 2>/dev/null || echo 0)"
  max_w="$(cat "${d}/max_link_width" 2>/dev/null || echo 0)"
  cur_s="$(cat "${d}/current_link_speed" 2>/dev/null | awk '{print $1}' || echo 0)"
  max_s="$(cat "${d}/max_link_speed" 2>/dev/null | awk '{print $1}' || echo 0)"
  emit "llm_pcie_link_width{device=\"${bus}\"} ${cur_w:-0}"
  emit "llm_pcie_link_width_max{device=\"${bus}\"} ${max_w:-0}"
  emit "llm_pcie_link_speed_gt{device=\"${bus}\"} ${cur_s:-0}"
  emit "llm_pcie_link_speed_gt_max{device=\"${bus}\"} ${max_s:-0}"
done

# --- PLE-Speicher und Modell -------------------------------------------------
# Eine Familie nur liefern, wenn ihre Voraussetzung auf diesem Rechner vorhanden
# ist (ple_configured aus lib/common.sh, dieselbe Regel wie im Doctor). Ein
# fehlender Messwert heisst "hier gibt es nichts zu messen"; eine Null aus einem
# Beispiel-Pfad, den es nie gab, laesst PleSpeicherFehlt dauerhaft feuern.
if ple_configured; then
  if have mountpoint && mountpoint -q "${PLE_STORAGE_MOUNT}" 2>/dev/null; then
    emit "llm_ple_mounted 1"
  else
    emit "llm_ple_mounted 0"
  fi
  if grep -qE 'llm-ple|ple-ext4|ple-nvme' /etc/fstab 2>/dev/null; then
    emit "llm_ple_in_fstab 1"
  else
    emit "llm_ple_in_fstab 0"
  fi
  [[ -f "${PLE_STORAGE_IMAGE}" ]] && emit "llm_ple_backing_bytes $(du -sb "${PLE_STORAGE_IMAGE}" 2>/dev/null | awk '{print $1}')"
fi
model_dir="${LLM_MODELS_DIR}/$(basename "${MODEL_ID}")"
if [[ -d "${model_dir}" ]]; then
  emit "llm_model_shard_files $(find "${model_dir}" -maxdepth 1 -name '*.safetensors' 2>/dev/null | wc -l)"
  emit "llm_model_incomplete_files $(find "${model_dir}" -maxdepth 1 -name '*.incomplete' 2>/dev/null | wc -l)"
fi

# --- CDI-Alter --------------------------------------------------------------
if [[ -f /etc/cdi/nvidia.yaml ]]; then
  mtime="$(stat -c %Y /etc/cdi/nvidia.yaml 2>/dev/null || echo "$(date +%s)")"
  emit "llm_gpu_cdi_age_seconds $(( $(date +%s) - mtime ))"
fi

# --- NVMe SMART (sudo noetig; ohne sudo nur llm_smart_available=0) ----------
smart_ok=0
# In WSL sind die Platten virtuelle VHDs ohne zugreifbare SMART-Daten; ein
# sudo-Aufruf pro Geraet und 30s-Sekunde fluellt nur das Journal mit
# Auth-Fehlern. Deshalb auf WSL-Hosts komplett ueberspringen.
if have smartctl && ! grep -qi microsoft /proc/version; then
  for dev in /dev/nvme[0-9] /dev/sd[a-z]; do
    [[ -e "${dev}" ]] || continue
    json="$(sudo -n smartctl --json=c -a "${dev}" 2>/dev/null || true)"
    [[ -n "${json}" ]] || continue
    smart_ok=1
    if printf '%s' "${json}" | SMART_DEV="$(basename "${dev}")" python3 "${root}/scripts/lib/smart_metrics.py" >> "${raw}" 2>/dev/null; then
      :
    fi
  done
fi
emit "llm_smart_available ${smart_ok}"

# --- letzte Messung ----------------------------------------------------------
latest="$(ls -1t "${root}/state/benchmarks"/*.json 2>/dev/null | head -1 || true)"
if [[ -n "${latest}" ]]; then
  BENCH_FILE="${latest}" python3 "${root}/scripts/lib/bench_metrics.py" >> "${raw}" 2>/dev/null || true
fi

emit "llm_infra_collect_ok 1"
emit "llm_infra_collect_timestamp_seconds $(date +%s)"

# HELP/TYPE-Zeilen ergaenzen: der Textfile-Collector verwirft eine ganze Datei,
# wenn nur eine einzige Familie keine Typangabe hat.
# Lokaler HTTPS-Proxy (llm-proxy): eigene Kennzahl, weil AGENTS.md fuer jeden
# neuen Dienst ein Metrikziel verlangt. Die Caddy-Admin-API liefert /metrics nur
# auf ihrer eigenen Loopback-Schnittstelle (Versuch ueber einen inneren Lauscher
# brachte 403), deshalb misst hier der bestehende Sammler die beiden benannten
# URLs selbst - dasselbe Muster wie bei den PLE-Werten: gemessen, nicht geraten.
proxy_homepage=0
proxy_grafana=0
if have curl && curl -fsS -m 5 -o /dev/null https://homepage.localhost/ 2>/dev/null; then
  proxy_homepage=1
fi
if have curl && curl -fsS -m 5 -o /dev/null https://grafana.localhost/grafana/api/health 2>/dev/null; then
  proxy_grafana=1
fi
emit "llm_local_proxy_homepage_up ${proxy_homepage}"
emit "llm_local_proxy_grafana_up ${proxy_grafana}"

if ! python3 "${root}/scripts/lib/assemble_textfile.py" "${raw}" > "${tmp}"; then
  printf 'FEHLER: Kennzahlen konnten nicht zusammengestellt werden.\n' >&2
  exit 1
fi
if [[ "${dry_run}" == 1 ]]; then
  printf '%s\n' "--- Pruefausgabe (${tmp}) ---"
  head -20 "${tmp}"
  printf '...\n%s Zeilen, Datei waere gueltig\n' "$(wc -l < "${tmp}")"
  exit 0
fi
install -d -m 0755 "${TEXTFILE_DIR}"
mv -f "${tmp}" "${TEXTFILE_DIR}/host-facts.prom"
chmod 0644 "${TEXTFILE_DIR}/host-facts.prom"
printf 'Host-Kennzahlen geschrieben: %s (%s Zeilen)\n' "${TEXTFILE_DIR}/host-facts.prom" \
  "$(wc -l < "${TEXTFILE_DIR}/host-facts.prom")"
