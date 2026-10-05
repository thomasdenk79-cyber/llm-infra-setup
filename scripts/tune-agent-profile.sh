#!/usr/bin/env bash
# Agent-Profil fuer Pennyroyal (vom Runner-Task PENNY-TUNE-1 gefahren):
# HiCache L2 auf 24 GiB, MAX_RUNNING 8 / Mamba 32 / graph bs 8 (4 Slots je
# Anfrage wie im Referenzprofil), Memory-Saver aus, Sleep aus.
# Der Restart laeuft nur, wenn KEINE Anfragen und KEINE Agenten laufen
# (Guard des apply-runtime-unit.sh + eigener AgentScan).
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
source lib/common.sh

DESIRED_HICACHE=24
DESIRED_MAX_RUNNING=8
DESIRED_MAX_MAMBA=32
DESIRED_GRAPH_BS=8
UNIT="$XDG_RUNTIME_DIR/systemd/user/pennyroyal.service"

log 'Ist-Zustand der aktiven Unit wird gelesen.'
mapfile -t ACTIVE_ENV < <(systemctl --user show pennyroyal.service -p Environment --value | tr ' ' '\n')
want=(PENNY_HICACHE_SIZE_GB=$DESIRED_HICACHE MAX_RUNNING_REQUESTS=$DESIRED_MAX_RUNNING MAX_MAMBA_CACHE_SIZE=$DESIRED_MAX_MAMBA PENNY_CUDA_GRAPH_MAX_BS=$DESIRED_GRAPH_BS PENNY_ENABLE_MEMORY_SAVER=0 PENNY_SLEEP_ON_IDLE=0)
drift=0
for w in "${want[@]}"; do
  grep -qx "$w" <<<"$(printf '%s\n' "${ACTIVE_ENV[@]}")" || { log "DRIFT: $w noch nicht aktiv"; drift=1; }
done
if (( drift == 0 )); then
  log 'Agent-Profil bereits aktiv - nichts zu tun.'
  exit 0
fi

# Agenten-Guard: ein laufender Chat-/Codex-/Agentenprozess blockiert den Neustart.
if pgrep -f 'opencode run|opencode serve|agents/qwen\.sh|agents/luna\.sh|codex exec' >/dev/null 2>&1; then
  log 'BLOCKIERT: laufende Agentensitzung - warte auf fensterfreies Intervall.'
  exit 0
fi

log 'Quadlet wird mit Agent-Profil neu erzeugt.'
export PENNY_HICACHE_SIZE_GB=$DESIRED_HICACHE
export PENNY_MAX_RUNNING_REQUESTS=$DESIRED_MAX_RUNNING
export PENNY_MAX_MAMBA_CACHE_SIZE=$DESIRED_MAX_MAMBA
export PENNY_CUDA_GRAPH_MAX_BS=$DESIRED_GRAPH_BS
export PENNY_ENABLE_MEMORY_SAVER=0
export PENNY_SLEEP_ON_IDLE=0
./scripts/50-install-pennyroyal.sh

log 'Anwenden mit Idle-Schutz (bricht bei laufenden Anfragen ab).'
if ! PENNYROYAL_PROTECT=0 ./scripts/apply-runtime-unit.sh --force; then
  log 'Anwenden fehlgeschlagen ( vermutlich Anfragen ) - späterer Wiederholungsversuch.'
  exit 0
fi

log 'Warte auf Health 200 (Kaltstart bis 40 Minuten).'
for _ in $(seq 1 160); do
  if curl -fsS --max-time 5 http://127.0.0.1:8001/health >/dev/null 2>&1; then
    log 'Pennyroyal wieder healthy.'
    podman logs --tail 400 pennyroyal > "$root/logs/agent-profile-candidate-boot.log" 2>&1 || true
    git -C "$root" add quadlet/pennyroyal.container config/host.env 2>/dev/null || true
    git -C "$root" diff --cached --quiet || git -C "$root" commit -m "ops: agent profile - hicache 24 GiB, max_running 8, mamba 32, memory_saver off" || true
    exit 0
  fi
  sleep 15
done
echo 'FEHLER: Health 200 nach 40 Minuten nicht erreicht.' >&2
exit 1
