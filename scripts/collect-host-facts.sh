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
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${PLE_STORAGE_IMAGE:=/srv/llm/ple-nvme.ext4}"
: "${PLE_STORAGE_MOUNT:=/srv/llm/ple-ext4}"
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
for unit in pennyroyal litellm litellm-postgres open-webui homepage prometheus \
            grafana loki alloy dozzle llm-node-exporter llm-gpu-exporter; do
  if systemctl --user is-active --quiet "${unit}.service" 2>/dev/null; then state=1; else state=0; fi
  emit "llm_unit_active{unit=\"${unit}\"} ${state}"
done
for timer in llm-infra-collect-facts llm-runtime-watchdog; do
  if systemctl --user is-active --quiet "${timer}.timer" 2>/dev/null; then state=1; else state=0; fi
  emit "llm_timer_active{timer=\"${timer}\"} ${state}"
done

# --- Laufzeit der Runtime ---------------------------------------------------
# systemd kennt den Startzeitpunkt der Haupteinheit; daraus die Betrieitszeit.
uptime_raw="$(systemctl --user show pennyroyal.service -p ExecMainStartTimestamp --value 2>/dev/null || true)"
if [[ -n "${uptime_raw}" && "${uptime_raw}" != "n/a" ]]; then
  uptime_seconds="$(DATE_VALUE="${uptime_raw}" python3 -c '
import datetime, os
raw = os.environ["DATE_VALUE"].strip()
try:
    when = datetime.datetime.strptime(raw, "%a %Y-%m-%d %H:%M:%S %Z")
except ValueError:
    raise SystemExit(0)
now = datetime.datetime.now()
print(max(0, int((now - when).total_seconds())))
' 2>/dev/null || true)"
  if [[ -n "${uptime_seconds}" ]]; then
    emit "llm_runtime_uptime_seconds ${uptime_seconds}"
  fi
fi

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
if mountpoint -q "${PLE_STORAGE_MOUNT}" 2>/dev/null; then
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
if have smartctl; then
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
