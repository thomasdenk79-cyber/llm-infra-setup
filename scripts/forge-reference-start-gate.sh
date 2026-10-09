#!/usr/bin/env bash
# reference-start-gate.sh -- ExecStartPre of pennyroyal.service.
# 1) Refuse to start the reference while the SM120 candidate container is running
#    (two 90 GiB model loads on one GPU = the OOM seen 2026-10-08 19:34/19:36).
# 2) Log WHO started the unit (process tree snapshot) so stray starters can be found.
LOG="$HOME/forge/logs/reference-start.log"
mkdir -p "$(dirname "$LOG")"
{
  echo "=== $(date -Is) pennyroyal.service start requested"
  echo "candidate running: $(podman ps --format '{{.Names}}' 2>/dev/null | grep -x 'flash-next-sm120' || echo no)"
  ps -eo pid,ppid,etimes,user,args --forest 2>/dev/null | grep -i "systemctl\|control.py\|run_window\|forge-guard\|hermes\|watchdog\|apply-runtime" | grep -v grep | cut -c1-200
} >> "$LOG" 2>&1
if podman ps --format '{{.Names}}' 2>/dev/null | grep -qx 'flash-next-sm120'; then
  echo "BLOCKED: candidate flash-next-sm120 is running; refusing to start the reference" | tee -a "$LOG" >&2
  exit 1
fi
exit 0
