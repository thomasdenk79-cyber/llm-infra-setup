#!/usr/bin/env bash
# Ein-Befehl-Einrichtung: Qwen3.8 Flash Next + Pennyroyal + komplette Umgebung.
#
#   ./setup.sh                 alles ausfuehren (idempotent)
#   ./setup.sh --dry-run       nur anzeigen, was gemacht wuerde
#   ./setup.sh --check         nur Voraussetzungen und Zustand pruefen
#
# Steuernde Umgebungsvariablen (alle optional):
#   AUTO_REBOOT=1              nach dem Treiberbau selbst neu starten
#   DOWNLOAD_MODEL=0           Modell-Download ueberspringen
#   START_RUNTIME=0            Runtime nicht starten (nur vorbereiten)
#   INSTALL_PACKAGES=0         Paketinstallation ueberspringen
#   PROTECT_RUNTIME=1          laufende Runtime weder starten noch stoppen
#   RUNTIME_WAIT_SECONDS=1800  Wartezeit beim Kaltstart
#
# Wiederkommen nach einem Abbruch ist der Normalfall: derselbe Befehl erkennt,
# was schon fertig ist, und macht nur die fehlenden Schritte.
set -Eeuo pipefail

root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
source "${root}/lib/units.sh"
source "${root}/lib/secrets.sh"

AUTO_REBOOT="${AUTO_REBOOT:-0}"
INSTALL_PACKAGES="${INSTALL_PACKAGES:-1}"
DOWNLOAD_MODEL="${DOWNLOAD_MODEL:-1}"
START_RUNTIME="${START_RUNTIME:-1}"
API_TEST="${API_TEST:-1}"
PROTECT_RUNTIME="${PROTECT_RUNTIME:-0}"
RETRY_ATTEMPTS="${RETRY_ATTEMPTS:-8}"
RETRY_DELAY="${RETRY_DELAY:-10}"
export RETRY_ATTEMPTS RETRY_DELAY

dry=0; check_only=0
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    --check) check_only=1 ;;
    -h|--help) sed -n '2,25p' "$0"; exit 0 ;;
    *) echo "unbekanntes Argument: $a  (hilfe: ./setup.sh --help)" >&2; exit 2 ;;
  esac
done

lock_file="${XDG_RUNTIME_DIR:-/tmp}/llm-infra-setup.lock"
exec 9>"${lock_file}"
if ! flock -n 9; then
  echo 'Es laeuft bereits ein setup-Durchlauf. Bitte warten und danach erneut starten.' >&2
  exit 75
fi

[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
export ZFS_POOL="${ZFS_POOL:-}"
export STORAGE_ROOT="${STORAGE_ROOT:-/srv}"
export MODEL_ID="${MODEL_ID:-RadixArk/Qwen3.8-Flash-Next-NVFP4}"
export PENNYROYAL_IMAGE="${PENNYROYAL_IMAGE:-ghcr.io/jpezzulli/sglang-rtxpro6000:v2.5.3}"
export PENNYROYAL_PORT="${PENNYROYAL_PORT:-8001}"

status_file="${root}/state/setup.status"
mkdir -p "${root}/state"
status() { printf '%s\t%s\n' "$(date -Is)" "$*" | tee -a "${status_file}"; }
do_step() {
  local what="$1"; shift
  if [[ "${dry}" == 1 ]]; then printf '[trocken] wuerde ausfuehren: %s\n' "$*"; return 0; fi
  status "${what}"; log "+ $*"; "$@"
}

if [[ "${check_only}" == 1 ]]; then
  run "${root}/scripts/doctor.sh"
  exit $?
fi

if [[ ! -f "${root}/config/host.env" ]]; then
  echo
  echo 'Es fehlt noch die lokale Konfiguration. Einmalig anlegen:'
  echo '    cp config/host.env.example config/host.env'
  echo 'Danach erneut: ./setup.sh'
  echo
  echo 'Die Defaults passen fuer einen Rechner mit /srv-ZFS-Pool und RTX PRO 6000.'
  exit 2
fi
status 'started'

# --- Phase 0: eGPU/Thunderbolt host stability -------------------------------
do_step host-power-stability make host-power-stability

# --- Phase 1: Speicher ------------------------------------------------------
do_step zfs make zfs

# --- Phase 2: Pakete und Werkzeuge -----------------------------------------
if [[ "${INSTALL_PACKAGES}" == 1 ]] && ! command -v podman >/dev/null 2>&1; then
  do_step packages retry make install
fi
do_step operator-tools retry make tools

# --- Phase 3: Treiber -------------------------------------------------------
if ! nvidia-smi -L >/dev/null 2>&1; then
  do_step nvidia-driver retry make nvidia-driver
  echo
  echo 'Der NVIDIA-Treiber ist eingebaut, aber der laufende Kernel sieht die GPU noch nicht.'
  echo 'Ein Neustart ist noetig; dasselbe Skript danach einfach erneut ausfuehren.'
  echo '  sudo systemctl reboot && ./setup.sh    (beim naechsten Login)'
  if [[ "${AUTO_REBOOT}" == 1 ]]; then run sudo systemctl reboot; fi
  status 'waiting-for-reboot'
  exit 0
fi

# --- Phase 4: Podman und CDI ------------------------------------------------
do_step podman retry make podman

# --- Phase 5: Modell und Image parallel ------------------------------------
model_job=""; image_job=""
if [[ "${DOWNLOAD_MODEL}" == 1 ]]; then
  model_dir="${LLM_MODELS_DIR:-/srv/llm/models}/$(basename "${MODEL_ID}")"
  if [[ -f "${model_dir}/config.json" ]] && ! find "${model_dir}" -path "${model_dir}/.cache" -prune -o -type f -name '*.incomplete' -print -quit | grep -q .; then
    status 'model-present'; log 'Modell ist bereits vollständig; Download wird uebersprungen.'
    do_step model-verify retry make model-verify
  else
    status 'model-download-start'
    ( retry make model >"${root}/state/model-download.log" 2>&1 ) & model_job=$!
    echo "Modell-Download laeuft im Hintergrund (Log: state/model-download.log)"
  fi
fi
if [[ "${START_RUNTIME}" == 1 ]]; then
  status 'pennyroyal-image-start'
  ( retry make pennyroyal >"${root}/state/pennyroyal-install.log" 2>&1 ) & image_job=$!
  echo "Image-Download laeuft im Hintergrund (Log: state/pennyroyal-install.log)"
fi
if [[ -n "${model_job}" ]]; then
  if wait "${model_job}"; then status 'model-download-done'; do_step model-verify retry make model-verify
  else status 'model-download-failed'; echo 'Modell-Download fehlgeschlagen. Log: state/model-download.log' >&2; exit 1; fi
fi
[[ -n "${image_job}" ]] && wait "${image_job}"

# --- Phase 6: PLE-Speicher und Deployment ----------------------------------
do_step ple-nvme make ple-nvme
do_step deploy make deploy-non-gpu

# --- Phase 7: Runtime starten und API-Test ---------------------------------
if [[ "${START_RUNTIME}" == 1 && "${PROTECT_RUNTIME}" != 1 ]]; then
  do_step deploy-ready make deploy-ready
  if [[ "${API_TEST}" == 1 ]]; then
    status 'api-test'
    curl -fsS --max-time 300 -H 'Content-Type: application/json' \
      -d '{"model":"pennyroyal","messages":[{"role":"user","content":"Reply with exactly: Pennyroyal API OK"}],"max_tokens":16,"stream":false}' \
      "http://127.0.0.1:${PENNYROYAL_PORT}/v1/chat/completions" | tee "${root}/state/api-smoke.json"
    echo
  fi
elif [[ "${PROTECT_RUNTIME}" == 1 ]]; then
  echo 'PROTECT_RUNTIME=1: die laufende Runtime wurde nicht angefasst.'
fi

# --- Phase 8: OpenCode-Anbindung (ueberschreibt nichts) --------------------
opencode_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/opencode"
target_json="${opencode_dir}/opencode.json"
candidate="$(mktemp)"
cat > "${candidate}" <<EOF
{
  "\$schema": "https://opencode.ai/config.json",
  "provider": {
    "local-pennyroyal": {
      "npm": "@ai-sdk/openai-compatible",
      "name": "Local Pennyroyal Qwen",
      "options": { "baseURL": "http://127.0.0.1:${PENNYROYAL_PORT}/v1", "apiKey": "local" },
      "models": { "pennyroyal": { "name": "Qwen3.8 Flash Next (local)" } }
    }
  },
  "model": "local-pennyroyal/pennyroyal"
}
EOF
if [[ -f "${target_json}" ]] && ! diff -q "${target_json}" "${candidate}" >/dev/null 2>&1; then
  install -D -m 0644 "${candidate}" "${target_json}.llm-infra"
  echo 'OpenCode-Konfiguration existiert bereits und wurde NICHT geaendert.'
  echo 'Vorschlag liegt nebenan: '"${target_json}.llm-infra"
  echo 'Pruefen und ggf. selbst uebernehmen: diff ... && cp ...'
elif [[ ! -f "${target_json}" ]]; then
  install -D -m 0644 "${candidate}" "${target_json}"
  echo 'OpenCode-Konfiguration neu angelegt: '"${target_json}"
fi
rm -f "${candidate}"

status 'complete'
echo
echo '=========================================================='
echo ' Einrichtungslauf beendet. Was jetzt gilt, zeigt der Check:'
echo '   ./scripts/doctor.sh'
echo ' Kurzfassung:'
echo '   Portal   http://127.0.0.1:3002'
echo '   Chat     http://127.0.0.1:3001'
echo '   API      http://127.0.0.1:4000 (Gateway) / :'"${PENNYROYAL_PORT}"' (direkt)'
echo '   Zugangs  ./scripts/show-credentials.sh'
echo '=========================================================='
run "${root}/scripts/doctor.sh" --short || true
