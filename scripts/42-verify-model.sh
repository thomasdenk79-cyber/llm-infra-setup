#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
source "${root}/lib/common.sh"
[[ -f "${root}/config/host.env" ]] && source "${root}/config/host.env"
[[ -f "${root}/config/model.env" ]] && source "${root}/config/model.env"
: "${LLM_MODELS_DIR:=/srv/llm/models}"
: "${MODEL_ID:=RadixArk/Qwen3.8-Flash-Next-NVFP4}"
target="${LLM_MODELS_DIR}/$(basename "${MODEL_ID}")"
[[ -f "${target}/config.json" ]] || { log "Missing config.json in ${target}"; exit 1; }
# Hugging Face keeps resumable cache markers below .cache even after the files in
# --local-dir are complete. Only markers in the model payload itself are errors.
if find "${target}" -path "${target}/.cache" -prune -o -type f -name '*.incomplete' -print -quit | grep -q .; then
  log 'Incomplete model files remain outside the Hugging Face cache'; exit 1
fi
python - "${target}" <<'PY'
import json
import pathlib
import sys

target = pathlib.Path(sys.argv[1])
json.loads((target / "config.json").read_text())
index = target / "model.safetensors.index.json"
if not index.is_file():
    raise SystemExit("Missing model.safetensors.index.json")
payload = json.loads(index.read_text())
files = set(payload.get("weight_map", {}).values())
missing = sorted(name for name in files if not (target / name).is_file())
empty = sorted(name for name in files if (target / name).stat().st_size == 0)
if missing:
    raise SystemExit(f"Missing indexed safetensors: {', '.join(missing[:5])}")
if empty:
    raise SystemExit(f"Empty indexed safetensors: {', '.join(empty[:5])}")
print(f"indexed_safetensors={len(files)}")
PY
count=$(find "${target}" -path "${target}/.cache" -prune -o -type f -name '*.safetensors' -print | wc -l)
((count > 0)) || { log 'No safetensors files found'; exit 1; }
size=$(du -sh "${target}" | awk '{print $1}')
revision='unavailable'
if command -v hf >/dev/null 2>&1; then
  revision=$(hf models info "${MODEL_ID}" --expand sha --format json 2>/dev/null | python -c 'import json,sys; print(json.load(sys.stdin).get("sha", "unavailable"))' || true)
fi
[[ -n "${revision}" ]] || revision='unavailable'
lock="${root}/versions.lock"
if [[ -f "${lock}" && "${revision}" != unavailable ]]; then
  MODEL_ID_VALUE="${MODEL_ID}" MODEL_REVISION_VALUE="${revision}" python - "${lock}" <<'PY'
import os
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lines = path.read_text().splitlines()
updates = {
    "model_id": os.environ["MODEL_ID_VALUE"],
    "model_revision": os.environ["MODEL_REVISION_VALUE"],
}
seen = set()
result = []
for line in lines:
    key = line.split(":", 1)[0] if ":" in line and not line.startswith("#") else ""
    if key in updates:
        result.append(f"{key}: {updates[key]}")
        seen.add(key)
    else:
        result.append(line)
for key, value in updates.items():
    if key not in seen:
        result.append(f"{key}: {value}")
path.write_text("\n".join(result) + "\n")
PY
fi
printf 'model_id=%s\npath=%s\nsize=%s\nsafetensor_files=%s\nrevision=%s\n' "$MODEL_ID" "$target" "$size" "$count" "${revision}"
