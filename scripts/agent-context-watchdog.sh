#!/usr/bin/env bash
# Beobachtet KV-Druck und Agentenlast; greift nicht in laufende Prozesse ein.
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
metrics_url="${SGLANG_METRICS_URL:-http://127.0.0.1:8002/metrics}"
warn_ratio="${AGENT_KV_WARN_RATIO:-0.85}"
critical_ratio="${AGENT_KV_CRITICAL_RATIO:-0.95}"
state_dir="$root/state/agent-context"
mkdir -p "$state_dir"
metrics="$(curl -fsS --max-time 8 "$metrics_url" 2>/dev/null || true)"
metric() { awk -v n="$1" '$0 ~ n"[{]" {print $NF; exit}' <<<"$metrics"; }
max="$(metric 'sglang:max_total_num_tokens')"; used="$(metric 'sglang:kv_used_tokens')"
available="$(metric 'sglang:kv_available_tokens')"; pending="$(metric 'sglang:pending_prealloc_token_usage')"
running="$(metric 'sglang:num_running_reqs')"; queued="$(metric 'sglang:num_queue_reqs')"
if [[ "$max" =~ ^[0-9.]+$ && "$used" =~ ^[0-9.]+$ ]]; then
  ratio="$(awk -v u="$used" -v m="$max" 'BEGIN{if(m>0) printf "%.4f",u/m; else print "0"}')"
else
  ratio="n/a"
fi
agents="$(pgrep -fc 'opencode run' || true)"
printf '%s kv_used=%s kv_max=%s kv_available=%s kv_ratio=%s pending_prealloc=%s running=%s queued=%s opencode_agents=%s\n' \
  "$(date --iso-8601=seconds)" "$used" "$max" "$available" "$ratio" "$pending" "$running" "$queued" "$agents" | tee "$state_dir/latest.txt"
if [[ "$ratio" != n/a ]] && awk -v r="$ratio" -v c="$critical_ratio" 'BEGIN{exit !(r>=c)}'; then
  printf 'KV pressure critical: compact or pause the highest relative agent context before admitting more work.\n' | tee "$state_dir/pressure" >/dev/null
elif [[ "$ratio" != n/a ]] && awk -v r="$ratio" -v w="$warn_ratio" 'BEGIN{exit !(r>=w)}'; then
  printf 'KV pressure warning: avoid admitting new large-context agents.\n' | tee "$state_dir/pressure" >/dev/null
else
  rm -f "$state_dir/pressure"
fi
