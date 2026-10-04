#!/usr/bin/env bash
set -Eeuo pipefail
variant="${1:?Variante fehlt}"
worktree="$(realpath -- "${2:?Worktree fehlt}")"
run_dir="$(realpath -- "${3:?Laufverzeichnis fehlt}")"
attempt="${4:-1}"
stamp="$(date -u +%Y%m%dT%H%M%SZ)"
slug="$(printf '%s' "$variant" | tr '[:upper:]' '[:lower:]')"
doc="$worktree/docs/variants/variant-${slug}-benchmark-${stamp}.md"
mkdir -p "$(dirname "$doc")"
{
  echo "# Variante $variant: bestandener Benchmark"
  echo
  echo "- Zeitpunkt UTC: \`$stamp\`"
  echo "- Matrixversuch: \`$attempt\`"
  echo "- Worktree: \`$worktree\`"
  echo
  echo '## Benchmarkwerte'
  echo
  echo '| Profil | Requests ok | Fehler | steady tok/s Median | aggregiert tok/s | TTFT Median |'
  echo '|---|---:|---:|---:|---:|---:|'
  for log in "$run_dir/$variant"/benchmark-c*.log; do
    [[ -f "$log" ]] || continue
    profile="$(basename "$log" .log | sed 's/^benchmark-//')"
    json="$(rg -o '\{"steady_tokens_per_second_median"[^}]*\}' "$log" | tail -1 || true)"
    if [[ -n "$json" ]]; then
      python3 - "$profile" "$json" <<'PY2'
import json,sys
d=json.loads(sys.argv[2])
print(f"| {sys.argv[1]} | {d.get('requests_ok','n/a')} | {d.get('errors','n/a')} | {d.get('steady_tokens_per_second_median','n/a')} | {d.get('aggregate_tokens_per_second','n/a')} | {d.get('time_to_first_token_seconds_median','n/a')} |")
PY2
    else
      echo "| $profile | n/a | n/a | n/a | n/a | n/a |"
    fi
  done
  journal="$run_dir/$variant/journal.log"
  echo; echo '## Cache- und Laufzeitwerte'; echo
  echo '- KV-Cache:'; rg -i -m 1 'kv cache|kv_cache|kv-cache' "$journal" 2>/dev/null || true
  echo '- HiCache:'; rg -i -m 1 'hicache|hi cache' "$journal" 2>/dev/null || true
  echo '- Graph/PLE-Konfiguration:'; rg -i -m 3 'cuda graph|PLE NVMe table|mem_fraction|context_length|ple=.*backend|image=' "$journal" 2>/dev/null || true
  echo; echo 'Fehlende Werte sind im Laufprotokoll nicht vorhanden und werden nicht geschaetzt.'
} > "$doc"
git -C "$worktree" add "$doc"
git -C "$worktree" commit -m "$variant: record benchmark and cache metrics $stamp" >/dev/null
tag="variant-${slug}-passing-${stamp}"
git -C "$worktree" tag -a "$tag" -m "$variant passed benchmark with cache metrics $stamp"
git -C "$worktree" push origin HEAD --tags >/dev/null
printf 'Recorded %s (%s)\n' "$variant" "$tag"
