#!/usr/bin/env bash
# Vollstaendiger Startpfad nach Neustart oder GPU-Reconnect:
# prueft Voraussetzungen, erzeugt alle Units, installiert sie und startet den
# Stack - ohne eine laufende Runtime ungefragt neu zu starten.
#
#   ./scripts/deploy-ready.sh              alles pruefen und starten
#   ./scripts/deploy-ready.sh --check      nur Voraussetzungen pruefen
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"

check() {
  local rc=0
  command -v nvidia-smi >/dev/null 2>&1 || { echo 'FEHLT: nvidia-smi. Naechster Schritt: make nvidia-driver, dann Neustart.' >&2; return 1; }
  nvidia-smi -L >/dev/null 2>&1 || { echo 'FEHLT: GPU nicht sichtbar. eGPU anstecken und neu starten.' >&2; rc=1; }
  nvidia-ctk cdi list >/dev/null 2>&1 || { echo 'FEHLT: NVIDIA-CDI. Naechster Schritt: make podman' >&2; rc=1; }
  "${root}/scripts/42-verify-model.sh" >/dev/null 2>&1 || { echo 'FEHLT: Modell unvollstaendig. Naechster Schritt: make model' >&2; rc=1; }
  "${root}/scripts/47-setup-ple-storage.sh" --verify >/dev/null 2>&1 || { echo 'FEHLT: PLE-Speicher. Naechster Schritt: make ple-nvme' >&2; rc=1; }
  return "${rc}"
}

if [[ "${1:-}" == "--check" ]]; then
  check && echo 'OK: alle Voraussetzungen erfuellt'
  exit $?
fi

check || {
  echo
  echo 'Voraussetzungen nicht erfuellt. Der Stack wurde NICHT gestartet.'
  echo 'Einzelne Punkte nachholen und danach ./scripts/doctor.sh ausfuehren.'
  exit 1
}

run "${root}/scripts/47-setup-ple-storage.sh"
run "${root}/scripts/48-prepare-ple-nvme.sh"
run "${root}/scripts/50-install-pennyroyal.sh"
run "${root}/scripts/63-install-postgres.sh"
run "${root}/scripts/60-install-gateway.sh"
run "${root}/scripts/60-install-open-webui.sh"
run "${root}/scripts/60-install-homepage.sh"
run "${root}/scripts/60-install-monitoring.sh"
ensure_base_credentials
install -d -m 0755 "${HOME}/.local/share/llm-infra"/{postgres,open-webui}

already_running=0
unit_is_active pennyroyal.container && already_running=1

prune_legacy_units
install_units "${INFERENCE_UNITS[@]}"
systemd_reload
start_units llm-inference.network litellm-postgres.container
sleep 3
if [[ "${already_running}" == 1 ]]; then
  echo
  echo 'Pennyroyal laeuft bereits und wird NICHT neu gestartet (Kaltstart ~15 Minuten).'
  echo 'Falls die Unit-Datei anders ist als der Laeufer:'
  echo '  ./scripts/apply-runtime-unit.sh --list'
  echo '  ./scripts/apply-runtime-unit.sh --restart-only     (wann es passt)'
else
  start_units pennyroyal.container
fi
start_units litellm.container open-webui.container
run "${root}/scripts/runtime-watchdog.sh" || true
echo
echo 'Warten auf die Runtime (max. 20 Minuten, kalt 15 Minuten):'
run "${root}/scripts/wait-for-runtime.sh" || {
  echo 'Runtime nicht erreichbar. Log:'
  echo '  journalctl --user -u pennyroyal.service -n 120 --no-pager'
  exit 1
}
run "${root}/scripts/healthcheck.sh" || true
echo
echo 'Alles gestartet. Naechster Schritt: ./scripts/doctor.sh'
