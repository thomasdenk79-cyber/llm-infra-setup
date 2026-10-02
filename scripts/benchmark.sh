#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"; mkdir -p "$root/state/benchmarks"
profile="${1:-quick}"; concurrency="${2:-1}"; port="${PENNYROYAL_PORT:-8001}"; url="http://127.0.0.1:${port}/v1/chat/completions"
case "$profile" in quick) prompt='Explain ZFS in one sentence.'; max=256;; normal) prompt="$(printf 'Summarize this infrastructure design. %.0s' {1..500})"; max=1024;; long) prompt="$(printf 'Provide a detailed technical analysis. %.0s' {1..5000})"; max=1024;; *) echo 'usage: benchmark.sh [quick|normal|long] [concurrency]' >&2; exit 2;; esac
model="${BENCHMARK_MODEL:-qwen3.8-flash-next}"; ts="$(date -u +%Y%m%dT%H%M%SZ)"; json="$root/state/benchmarks/$ts.json"; md="$root/state/benchmarks/$ts.md"; start=$(date +%s%3N)
payload=$(python3 -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":int(sys.argv[3]),"stream":False}))' "$model" "$prompt" "$max")
errs=0; total=0; response="{}"
for i in $(seq 1 "$concurrency"); do out=$(curl --fail --silent --show-error --max-time 300 -H 'Content-Type: application/json' -d "$payload" "$url" 2>&1) || { errs=$((errs+1)); continue; }; total=$((total+1)); [[ "$i" == 1 ]] && response="$out"; done
end=$(date +%s%3N); elapsed=$((end-start)); python3 - "$json" "$profile" "$concurrency" "$elapsed" "$total" "$errs" "$response" <<'PY'
import json,sys,datetime
p,profile,conc,ms,ok,errors,response=sys.argv[1:]; d={"timestamp":datetime.datetime.now(datetime.timezone.utc).isoformat(),"profile":profile,"concurrency":int(conc),"elapsed_ms":int(ms),"successful_requests":int(ok),"errors":int(errors)}
try:
 x=json.loads(response); u=x.get('usage',{}); d.update({"prompt_tokens":u.get('prompt_tokens'),"completion_tokens":u.get('completion_tokens'),"total_tokens":u.get('total_tokens')})
except Exception: pass
open(p,'w').write(json.dumps(d,indent=2)+"\n")
PY
cat > "$md" <<EOF2
# Benchmark $ts

- Profile: **$profile**
- Concurrency: **$concurrency**
- Elapsed: **${elapsed}ms**
- Successful: **$total**; errors: **$errs**

Raw machine-readable result: $(basename "$json")
EOF2
cat "$md"; (( errs == 0 ))
