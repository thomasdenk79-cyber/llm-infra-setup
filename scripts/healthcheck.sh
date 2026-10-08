#!/usr/bin/env bash
# Schneller Systemcheck mit menschenlesbaren Naechsten Schritten.
# Abkuerzung fuer ./scripts/doctor.sh --short
set -uo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
: "${PENNYROYAL_PORT:=8001}"
: "${LITELLM_PORT:=4000}"
bad=0
ok(){ printf '\033[32m[OK]\033[0m    %s\n' "$*"; }
warn(){ printf '\033[33m[WARN]\033[0m  %s\n' "$*"; }
fail(){ printf '\033[31m[FAIL]\033[0m  %s\n' "$*"; bad=1; }

if ! command -v curl >/dev/null 2>&1; then fail 'curl fehlt' 'make install'
elif curl --fail --silent --show-error --max-time 8 "http://127.0.0.1:${PENNYROYAL_PORT}/health" >/dev/null 2>&1
then ok "Inferenz-API gesund (:${PENNYROYAL_PORT})"
else
  if systemctl --user is-active --quiet pennyroyal.service 2>/dev/null; then
    fail "Runtime-Unit laeuft, antwortet aber nicht (:${PENNYROYAL_PORT})" 'journalctl --user -u pennyroyal.service -n 120 --no-pager'
  else
    fail "Runtime ist nicht gestartet (:${PENNYROYAL_PORT})" 'make deploy-ready   (ohne GPU: make deploy-non-gpu)'
  fi
fi
if command -v podman >/dev/null 2>&1; then
  if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx pennyroyal; then ok 'Container pennyroyal laeuft'
  else warn 'Container pennyroyal laeuft nicht (noetig fuer Antworten)'; fi
else
  warn 'podman fehlt' 'make install'
fi
if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; then
  ok "GPU erreichbar ($(nvidia-smi --query-gpu=memory.used,memory.total --format=csv,noheader 2>/dev/null))"
else
  warn 'GPU nicht sichtbar' 'GPU anstecken, neu starten, dann make podman'
fi
if command -v zpool >/dev/null 2>&1; then
  if zpool list 2>/dev/null | awk 'NR>1 && $NF!="ONLINE"{bad=1} END{exit bad?1:0}'; then ok 'ZFS-Pools ONLINE'; else fail 'ZFS-Pool nicht ONLINE' 'zpool status'; fi
else
  warn 'ZFS-Werkzeuge nicht installiert'
fi
df -P /srv 2>/dev/null | awk 'NR==2 {gsub("%","",$5); if ($5+0>=90) {print "     [WARN]  /srv ist " $5 " % voll (Modell und PLE brauchen Platz)"; exit 1} else {print "     [OK]    /srv " $5 " % voll"} }' || bad=1
# /health ist durch den Master-Key geschuetzt und antwortet ohne Bearer mit 401 -
# das waere ein false negative. Die Lebensanzeige /health/liveliness ist keyless.
if [[ "${LITELLM_PORT}" != disabled ]]; then
  gw_code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${LITELLM_PORT}/health/liveliness" 2>/dev/null || echo 000)
  if [[ "${gw_code}" == 200 ]]; then
    ok 'Gateway (LiteLLM) gesund (liveliness keyless)'
  elif [[ "${gw_code}" == 000 ]]; then
    warn 'Gateway nicht erreichbar (optional)' 'make deploy-non-gpu'
  else
    warn "Gateway-Liveliness antwortet mit HTTP ${gw_code}" 'journalctl --user -u litellm.service -n 60 --no-pager'
  fi
fi
if (( bad == 0 )); then
  echo 'SYSTEM HEALTHY'
else
  echo
  echo 'Ausfuehrliche Diagnose mit allen naechsten Schritten:'
  echo '  ./scripts/doctor.sh'
fi
exit "${bad}"
