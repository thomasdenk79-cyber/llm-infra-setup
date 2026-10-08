#!/usr/bin/env bash
# Flash-Next FR-Spec with 524K context and HiCache/NIXL.
# Source credit: https://github.com/gabrielolympie/sglang-flashnext-sm120
set -euo pipefail
# Avoid synchronous RAM compaction for transient NumPy image arrays.
# Operators can opt back into NumPy huge-page advice; this is not a kernel policy.
export NUMPY_MADVISE_HUGEPAGE="${NUMPY_MADVISE_HUGEPAGE:-0}"
export SGLANG_MM_PREPROCESS_DEVICE="${SGLANG_MM_PREPROCESS_DEVICE:-cpu}"
export SGLANG_FORWARD_UNKNOWN_TOOLS="${SGLANG_FORWARD_UNKNOWN_TOOLS:-true}"
case "$SGLANG_MM_PREPROCESS_DEVICE" in
  cpu) IMAGE_PROCESSOR_BACKEND=pil ;;
  cuda:*) IMAGE_PROCESSOR_BACKEND=torchvision ;;
  *) echo "Choose SGLANG_MM_PREPROCESS_DEVICE=cpu or cuda:N" >&2; exit 1 ;;
esac

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="${REPO_ROOT:-$(cd -- "$SCRIPT_DIR/../.." && pwd)}"
SGLANG_EXE="${SGLANG_EXE:-$REPO_ROOT/.venv/bin/sglang}"
PYTHON="${PYTHON:-$(dirname "$SGLANG_EXE")/python}"
TARGET_MODEL="${TARGET_MODEL:?Set TARGET_MODEL to the Flash-Next checkpoint}"
CACHE_BASE="${CACHE_BASE:?Set CACHE_BASE to the durable compiler-cache root}"
NIXL_STORAGE_BASE="${NIXL_STORAGE_BASE:?Set NIXL_STORAGE_BASE to the FILE cache root}"
NIXL_CONFIG="${NIXL_CONFIG:-$SCRIPT_DIR/nixl-posix-frspec.toml}"
NAMESPACE_HELPER="$REPO_ROOT/scripts/pennyroyal/derive_namespace.py"
# Host-RAM HiCache tier: --hicache-size counts decimal GB (SGLang sizes the
# host pool at size * 1e9 bytes), not GiB. An unset PENNY_HICACHE_SIZE_GB keeps
# this recipe's qualified default. Zero disables the host HiCache tier for
# low-RAM hosts; positive values reserve that many decimal GB.
HICACHE_SIZE_GB="${PENNY_HICACHE_SIZE_GB:-32}"
if [[ ! "$HICACHE_SIZE_GB" =~ ^(0|[1-9][0-9]*)$ ]]; then
  echo "PENNY_HICACHE_SIZE_GB must be 0 or a positive integer number of GB, got '$HICACHE_SIZE_GB'" >&2
  exit 1
fi
source "$SCRIPT_DIR/chat-template.sh"
source "$SCRIPT_DIR/request-capacity.sh"
source "$SCRIPT_DIR/reasoning-effort.sh"
source "$SCRIPT_DIR/tp-devices.sh"

# Pin the qualified map and tokenizer: a different ID mapping changes draft
# proposals and must never silently reuse this representation's cache namespace.
TOKEN_MAP="$SCRIPT_DIR/frspec/flash-next-64k.pt"

CONTEXT_LENGTH=524288
PAGE_SIZE=64
# --- Stellgroessen fuer den Betrieb ---------------------------------------
# Alle Werte sind die bisherigen Qualifikationswerte; nur ausuchen, nicht erfinden.
# Jede Aenderung braucht einen Vorher/Nachher-Lauf:
#   MIN_TOKENS=180 ./scripts/benchmark.sh normal
# Erklaerung der einzelnen Hebel: docs/performance.md
MEM_FRACTION_STATIC="${PENNY_MEM_FRACTION_STATIC:-0.981}"
# Keep the value defined before `set -u` reaches diagnostics and namespace
# derivation.  The old fallback expanded the not-yet-defined variable
# PREFILL_CHUNK_SIZE and made every restart exit before SGLang started.
PREFILL_CHUNK_SIZE="${PENNY_CHUNKED_PREFILL_SIZE:-4096}"
CHUNKED_PREFILL_SIZE="$PREFILL_CHUNK_SIZE"
PREFILL_ARGS=()
if [[ -n "${PENNY_MAX_PREFILL_TOKENS:-}" ]]; then
  if [[ ! "${PENNY_MAX_PREFILL_TOKENS}" =~ ^[1-9][0-9]*$ ]] \
     || (( PENNY_MAX_PREFILL_TOKENS < PREFILL_CHUNK_SIZE )); then
    echo "PENNY_MAX_PREFILL_TOKENS must be a positive integer >= PENNY_CHUNKED_PREFILL_SIZE" >&2
    exit 1
  fi
  PREFILL_ARGS+=(--max-prefill-tokens "${PENNY_MAX_PREFILL_TOKENS}")
fi
SPEC_NUM_STEPS="${PENNY_SPEC_NUM_STEPS:-3}"
SPEC_EAGLE_TOPK="${PENNY_SPEC_EAGLE_TOPK:-1}"
SPEC_NUM_DRAFT_TOKENS="${PENNY_SPEC_NUM_DRAFT_TOKENS:-4}"
SLEEP_ON_IDLE="${PENNY_SLEEP_ON_IDLE:-1}"
ENABLE_MFU_METRICS="${PENNY_ENABLE_MFU_METRICS:-0}"
WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD="${PENNY_WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD:-0}"
case "$WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD" in
  0|1) ;;
  *) echo "PENNY_WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD must be 0 or 1, got '$WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD'" >&2; exit 1 ;;
esac
for value_name in MEM_FRACTION_STATIC SPEC_NUM_STEPS SPEC_EAGLE_TOPK SPEC_NUM_DRAFT_TOKENS SLEEP_ON_IDLE; do
  case "${!value_name}" in
    ''|*[!0-9.]*) echo "${value_name} muss eine Zahl sein, erhalten: '${!value_name}'" >&2; exit 1 ;;
  esac
done
if (( SPEC_NUM_DRAFT_TOKENS < SPEC_NUM_STEPS + 1 )); then
  echo "PENNY_SPEC_NUM_DRAFT_TOKENS (${SPEC_NUM_DRAFT_TOKENS}) muss mindestens PENNY_SPEC_NUM_STEPS + 1 sein" >&2
  exit 1
fi
# CUDA graph captures reserve memory otherwise available to the KV cache.
# Use either a precise decode batch list or a maximum batch size, not both.
CUDA_GRAPH_ARGS=()
if [[ -n "${PENNY_CUDA_GRAPH_BS_DECODE:-}" ]]; then
  if [[ -n "${PENNY_CUDA_GRAPH_MAX_BS:-}" ]]; then
    echo "Set only one of PENNY_CUDA_GRAPH_BS_DECODE and PENNY_CUDA_GRAPH_MAX_BS" >&2
    exit 1
  fi
  IFS=, read -r -a CUDA_GRAPH_BS_DECODE <<< "$PENNY_CUDA_GRAPH_BS_DECODE"
  previous_batch_size=0
  for batch_size in "${CUDA_GRAPH_BS_DECODE[@]}"; do
    if [[ ! "$batch_size" =~ ^[1-9][0-9]*$ ]] || (( batch_size <= previous_batch_size )); then
      echo "PENNY_CUDA_GRAPH_BS_DECODE must be ascending, unique positive integers separated by commas" >&2
      exit 1
    fi
    previous_batch_size="$batch_size"
  done
  CUDA_GRAPH_ARGS+=(--cuda-graph-bs-decode "${CUDA_GRAPH_BS_DECODE[@]}")
elif [[ -n "${PENNY_CUDA_GRAPH_MAX_BS:-}" ]]; then
  if [[ ! "${PENNY_CUDA_GRAPH_MAX_BS}" =~ ^[1-9][0-9]*$ ]]; then
    echo "PENNY_CUDA_GRAPH_MAX_BS muss eine positive Zahl sein" >&2; exit 1
  fi
  CUDA_GRAPH_ARGS+=(--cuda-graph-max-bs "${PENNY_CUDA_GRAPH_MAX_BS}")
fi
GRAPH_BATCHES="${PENNY_CUDA_GRAPH_BS_DECODE:-max:${PENNY_CUDA_GRAPH_MAX_BS:-SGLang-default}}"
if [[ "${PENNY_ENABLE_MEMORY_SAVER:-0}" == 1 ]]; then CUDA_GRAPH_ARGS+=(--enable-memory-saver); fi
# --- Wachstum der Laufzeit -------------------------------------------------
# Gemessen auf diesem Rechner (Logzeile "Decode batch ... mamba num: 4" bei einer
# laufenden Anfrage): jede aufgenommene Anfrage belegt vier Zustandsplaetze.
# Wer MAX_RUNNING_REQUESTS erhoht, ohne MAX_MAMBA_CACHE_SIZE mitzuheben, laeuft
# gegen die Plaetze statt gegen die Anfragen - und beides kostet Speicher, der
# dann dem Zeichenspeicher fehlt.
# SGLang v2.5.3 reports mamba_ratio=5 for this Flash-Next profile. Keep a
# configurable guard, but default to the measured runtime requirement.
SLOTS_PER_REQUEST="${PENNY_MAMBA_SLOTS_PER_REQUEST:-5}"
if [[ -n "${MAX_RUNNING_REQUESTS:-}" && -n "${MAX_MAMBA_CACHE_SIZE:-}" ]] \
   && (( MAX_MAMBA_CACHE_SIZE < MAX_RUNNING_REQUESTS * SLOTS_PER_REQUEST )); then
  echo "MAX_MAMBA_CACHE_SIZE (${MAX_MAMBA_CACHE_SIZE}) sollte mindestens ${SLOTS_PER_REQUEST} mal MAX_RUNNING_REQUESTS (${MAX_RUNNING_REQUESTS}) = $(( MAX_RUNNING_REQUESTS * SLOTS_PER_REQUEST )) sein, sonst bringen die extra Anfragen nichts." >&2
  exit 1
fi

SLEEP_ARGS=()
if [[ "${SLEEP_ON_IDLE}" == 1 ]]; then SLEEP_ARGS+=(--sleep-on-idle); fi
MFU_ARGS=()
if [[ "${ENABLE_MFU_METRICS}" == 1 ]]; then MFU_ARGS+=(--enable-mfu-metrics); fi

# TP1 is the qualified default; TP_SIZE=2 opts into the two-GPU experimental
# (not yet hardware-qualified) path: the NIXL namespace hashes tp_size, so
# the two topologies can never share one cache root, and the FR-Spec
# hot-vocab head is assembled across TP shards at startup (see
# python/sglang/srt/speculative/hot_vocab.py).
TP_SIZE="${TP_SIZE:-1}"
if [[ ! "$TP_SIZE" =~ ^[1-9][0-9]*$ ]]; then
  echo "TP_SIZE must be a positive integer" >&2
  exit 1
fi
COMPUTE_DTYPE=bfloat16
KV_DTYPE=fp8_e4m3
MAMBA_SSM_DTYPE=bfloat16
MAMBA_CONV_DTYPE=bfloat16
MAMBA_TRACK_INTERVAL=64
for path in "$SGLANG_EXE" "$PYTHON" "$NAMESPACE_HELPER"; do
  [[ -x "$path" ]] || { echo "Required executable missing: $path" >&2; exit 1; }
done
[[ -r "$NIXL_CONFIG" ]] || { echo "NIXL config missing: $NIXL_CONFIG" >&2; exit 1; }
[[ -f "$TARGET_MODEL/config.json" && -f "$TARGET_MODEL/model.safetensors.index.json" ]] || {
  echo "Incomplete target checkpoint: $TARGET_MODEL" >&2
  exit 1
}
[[ -f "$TARGET_MODEL/tokenizer.json" ]] || {
  echo "Target tokenizer missing: $TARGET_MODEL/tokenizer.json" >&2
  exit 1
}
[[ -f "$TOKEN_MAP" ]] || { echo "FR-Spec map missing: $TOKEN_MAP" >&2; exit 1; }
mkdir -p "$CACHE_BASE"/{huggingface,torch,torchinductor,triton,cuda,flashinfer,sglang/jit}
mkdir -p "$NIXL_STORAGE_BASE"

# Default to as many consecutive GPUs as TP requires (one scheduler process
# per visible device); an explicit CUDA_VISIBLE_DEVICES still wins.
if [[ -z "${CUDA_VISIBLE_DEVICES:-}" ]]; then
  CUDA_VISIBLE_DEVICES="$(seq -s, 0 $((TP_SIZE - 1)))"
fi
export CUDA_DEVICE_ORDER=PCI_BUS_ID CUDA_VISIBLE_DEVICES
export CUDA_HOME="${CUDA_HOME:-/usr/local/cuda}"
export CUDACXX="${CUDACXX:-$CUDA_HOME/bin/nvcc}"
export CC="${CC:-/usr/bin/gcc-15}" CXX="${CXX:-/usr/bin/g++-15}"
export CUDAHOSTCXX="${CUDAHOSTCXX:-$CXX}" TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-12.0}"
export PENNY_BUILD_JOBS="${PENNY_BUILD_JOBS:-4}"
export MAX_JOBS="${MAX_JOBS:-$PENNY_BUILD_JOBS}" CMAKE_BUILD_PARALLEL_LEVEL="${CMAKE_BUILD_PARALLEL_LEVEL:-$PENNY_BUILD_JOBS}"
export CARGO_BUILD_JOBS="${CARGO_BUILD_JOBS:-$PENNY_BUILD_JOBS}"
export FLASHINFER_NINJA_JOBS="${FLASHINFER_NINJA_JOBS:-$PENNY_BUILD_JOBS}" FLASHINFER_NVCC_THREADS="${FLASHINFER_NVCC_THREADS:-1}"
export TORCHINDUCTOR_COMPILE_THREADS="${TORCHINDUCTOR_COMPILE_THREADS:-$PENNY_BUILD_JOBS}"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

export HF_HOME="$CACHE_BASE/huggingface" XDG_CACHE_HOME="$CACHE_BASE"
export TORCH_HOME="$CACHE_BASE/torch" TORCHINDUCTOR_CACHE_DIR="$CACHE_BASE/torchinductor"
export TRITON_CACHE_DIR="$CACHE_BASE/triton" CUDA_CACHE_PATH="$CACHE_BASE/cuda"
export FLASHINFER_WORKSPACE_BASE="$CACHE_BASE/flashinfer"
export SGLANG_CACHE_DIR="$CACHE_BASE/sglang" SGLANG_JIT_CACHE_DIR="$CACHE_BASE/sglang/jit"
# WSL's CUDA/NCCL worker crashes with CUDA_ERROR_UNKNOWN if PyTorch's
# expandable_segments allocator is enabled (reproduced at init_process_group).
# Keep it opt-in; the WSL host profile sets PENNY_USE_EXPANDABLE_SEGMENTS=0.
if [[ "${PENNY_ENABLE_MEMORY_SAVER:-0}" == 1 || "${PENNY_USE_EXPANDABLE_SEGMENTS:-0}" != 1 ]]; then
  unset PYTORCH_CUDA_ALLOC_CONF
else
  export PYTORCH_CUDA_ALLOC_CONF="${PYTORCH_CUDA_ALLOC_CONF:-expandable_segments:True}"
fi
export SGLANG_NUMA_BIND_V2=false SGLANG_ALLOW_OVERWRITE_LONGER_CONTEXT_LEN=1
export SGLANG_MAMBA_CONV_DTYPE="$MAMBA_CONV_DTYPE"
export OMP_NUM_THREADS="${OMP_NUM_THREADS:-4}" MKL_NUM_THREADS="${MKL_NUM_THREADS:-4}"
export OPENBLAS_NUM_THREADS="${OPENBLAS_NUM_THREADS:-4}" NUMEXPR_NUM_THREADS="${NUMEXPR_NUM_THREADS:-4}"
export TOKENIZERS_PARALLELISM=false
LOADER_THREADS="${PENNY_LOADER_THREADS:-4}"
if [[ ! "${LOADER_THREADS}" =~ ^[1-9][0-9]*$ ]]; then
  echo "PENNY_LOADER_THREADS must be a positive integer" >&2
  exit 1
fi

# TP selects a topology, it never grants GPUs: refuse to launch when the
# requested ranks (plus a dedicated cuda:N preprocessor) exceed what is
# visible, instead of letting NCCL fail or the request be ignored. Runs
# after the durable cache environment so its $PYTHON probe sees the same
# cache locations as every later Python invocation.
pennyroyal_check_tp_devices "$TP_SIZE" "$SGLANG_MM_PREPROCESS_DEVICE"

# NVMe preflight imports Torch, Triton, FlashInfer and SGLang. Activate their
# durable cache locations before selecting the optional backend.
source "$SCRIPT_DIR/ple-backend.sh"
# Leave SGLang's KV capacity auto-sized unless the operator sets an explicit cap.
configure_max_total_tokens "${MAX_TOTAL_TOKENS:-}"

TARGET_OVERRIDES='{"text_config":{"rope_parameters":{"mrope_interleaved":true,"mrope_section":[11,11,10],"rope_type":"yarn","rope_theta":10000000,"partial_rotary_factor":0.25,"factor":2.0,"original_max_position_embeddings":262144}}}'
printf 'Pennyroyal profile: Flash-Next FR-Spec\n  runtime: %s\n  target: %s\n  token map: %s\n  cache root: %s\n  NIXL root: %s\n' \
  "$SGLANG_EXE" "$TARGET_MODEL" "$TOKEN_MAP" "$CACHE_BASE" "$NIXL_STORAGE_BASE"
echo "Stellgroessen: mem_fraction=${MEM_FRACTION_STATIC} chunked_prefill=${CHUNKED_PREFILL_SIZE} max_prefill=${PENNY_MAX_PREFILL_TOKENS:-SGLang-default} spec=${SPEC_NUM_STEPS}/${SPEC_EAGLE_TOPK}/${SPEC_NUM_DRAFT_TOKENS} sleep_on_idle=${SLEEP_ON_IDLE} mfu=${ENABLE_MFU_METRICS} graph_batches=${GRAPH_BATCHES} memory_saver=${PENNY_ENABLE_MEMORY_SAVER:-0} hicache=${HICACHE_SIZE_GB} ple=${PENNY_PLE_BACKEND:-auto} loader_threads=${LOADER_THREADS} drop_cache_after_load=${WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD} omp_threads=${OMP_NUM_THREADS} compile_threads=${TORCHINDUCTOR_COMPILE_THREADS} build_jobs=${PENNY_BUILD_JOBS}"

# --- Identitaet + WSL-Workarounds: unmissable, damit jeder Start pruefbar ist ----
{
  echo "======================= PENNYROYAL START: IDENTITAET ======================="
  if [[ -f /opt/sm120/build-info.json ]]; then
    echo "variant : FORK sm120 (test fork)  $("${PYTHON:-python3}" -c "import json;d=json.load(open('/opt/sm120/build-info.json'));print(' '.join(f'{k}={d.get(k)}' for k in ('fork_version','channel','commit','dirty','base_ref','built_at')))" 2>/dev/null)"
  else
    echo "variant : ORIGINAL Pennyroyal v2.5.3 (jpezzulli/sglang-rtxpro6000, kein /opt/sm120 build-info)"
  fi
  echo "sglang  : $("${PYTHON:-python3}" -c 'import sglang;print(sglang.__version__)' 2>/dev/null)  (+g<sha> = git-Commit der Quelle; Basis d00d88efc8 = Release v2.5.3)"
  echo "---------------------- WSL-WORKAROUNDS (effektive Werte) ---------------------"
  echo "WSL erkannt                          : $(grep -qi microsoft /proc/version 2>/dev/null && echo ja || echo nein)"
  echo "SGLANG_HICACHE_TORCH_PINNED_ALLOC    : ${SGLANG_HICACHE_TORCH_PINNED_ALLOC:-<nicht gesetzt>}   (1/true = torch cudaHostAlloc statt cudaHostRegister)"
  echo "PENNY_USE_EXPANDABLE_SEGMENTS        : ${PENNY_USE_EXPANDABLE_SEGMENTS:-<nicht gesetzt>}   (muss 0 sein auf WSL)"
  echo "PYTORCH_CUDA_ALLOC_CONF (effektiv)   : ${PYTORCH_CUDA_ALLOC_CONF:-<nicht gesetzt = expandable_segments AUS>}"
  echo "PENNY_ENABLE_MEMORY_SAVER            : ${PENNY_ENABLE_MEMORY_SAVER:-0}"
  echo "memlock (Bytes, /proc/self/limits)   : $(awk '/Max locked memory/ {print $4 " soft / " $5 " hard"}' /proc/self/limits 2>/dev/null)"
  echo "/dev/shm                             : $(df -h /dev/shm 2>/dev/null | awk 'NR==2 {print $2 " gesamt, " $3 " belegt"}')"
  echo "Host-RAM (MiB)                       : $(awk '/MemTotal|MemAvailable/ {printf "%s %d  ", $1, $2/1024}' /proc/meminfo)"
  echo "---------------------- Last / Admission (effektive Werte) -------------------"
  echo "max_running=${MAX_RUNNING_REQUESTS:-?} mamba_slots=${MAX_MAMBA_CACHE_SIZE:-?} slots/request-guard=${SLOTS_PER_REQUEST:-?} mem_fraction=${MEM_FRACTION_STATIC:-?} graph_bs=${GRAPH_BATCHES:-?} context=${PENNY_CONTEXT_LENGTH:-?}"
  echo "threads omp=${OMP_NUM_THREADS:-?} mkl=${MKL_NUM_THREADS:-?} openblas=${OPENBLAS_NUM_THREADS:-?} numexpr=${NUMEXPR_NUM_THREADS:-?} | build_jobs=${PENNY_BUILD_JOBS:-?} max_jobs=${MAX_JOBS:-?} inductor=${TORCHINDUCTOR_COMPILE_THREADS:-?}"
  echo "loader_threads=${LOADER_THREADS:-?} drop_cache_after_load=${WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD:-?} hicache_gb=${HICACHE_SIZE_GB:-?} ple=${PENNY_PLE_BACKEND:-?}"
  echo "==========================================================================="
} >&2
echo "Verifying the pinned FR-Spec map and tokenizer..."
read -r TOKEN_MAP_SHA _ < <(sha256sum "$TOKEN_MAP")
[[ "$TOKEN_MAP_SHA" == becfa41d394b86c26c632bea8f3c6ea64bbb76d7b238d8673c06afae21269f25 ]] || {
  echo "FR-Spec map does not match the bundled checksum" >&2; exit 1;
}
read -r TOKENIZER_SHA _ < <(sha256sum "$TARGET_MODEL/tokenizer.json")
[[ "$TOKENIZER_SHA" == 0997f410c57a1f4e53b09e4be8f4a172d90edd9564368fb0847030937229b9f3 ]] || {
  echo "Target tokenizer differs from the qualified FR-Spec tokenizer" >&2; exit 1;
}
SGLANG_REV="$(git -C "$REPO_ROOT" rev-parse --short=10 HEAD)"
TORCH_VERSION="$("$PYTHON" -c 'import torch; from sglang.srt.utils import resolve_mm_preprocess_device; resolve_mm_preprocess_device(); print(torch.__version__)')"
echo "Media preprocessing: $SGLANG_MM_PREPROCESS_DEVICE ($IMAGE_PROCESSOR_BACKEND); model GPU: cuda:0"
echo "Deriving NIXL namespace; checkpoint identity hashing may take time..."
NIXL_STORAGE="$("$NAMESPACE_HELPER" \
  --base-root "$NIXL_STORAGE_BASE" \
  --slug "qwen3_8_flash_next_frspec_524k_nextn_${SGLANG_REV}" \
  --git-repo "$REPO_ROOT" \
  --model "target=$TARGET_MODEL" \
  --field "chat_template_sha256=$CHAT_TEMPLATE_SHA" \
  --field "image_processor_backend=$IMAGE_PROCESSOR_BACKEND" \
  --field "mm_preprocess_device=$SGLANG_MM_PREPROCESS_DEVICE" \
  --field "draft_token_map_sha256=$TOKEN_MAP_SHA" \
  --field "online_mxfp8=$SGLANG_SM120_ONLINE_MXFP8" \
  --field "context_length=$CONTEXT_LENGTH" \
  --field "tp_size=$TP_SIZE" \
  --field "page_size=$PAGE_SIZE" \
  --field "compute_dtype=$COMPUTE_DTYPE" \
  --field "target_kv_dtype=$KV_DTYPE" \
  --field "speculative_algorithm=NEXTN" \
  --field "speculative_num_steps=3" \
  --field "speculative_eagle_topk=1" \
  --field "speculative_num_draft_tokens=4" \
  --field "speculative_draft_quantization=unquant" \
  --field "gdn_mtp_cache_mode=none" \
  --field "hicache_io_backend=kernel" \
  --field "hicache_mem_layout=page_first" \
  --field "mamba_ssm_dtype=$MAMBA_SSM_DTYPE" \
  --field "mamba_conv_dtype=$MAMBA_CONV_DTYPE" \
  --field "max_mamba_cache_size=$MAX_MAMBA_CACHE_SIZE" \
  --field "max_running_requests=$MAX_RUNNING_REQUESTS" \
  --field "mamba_radix_cache_strategy=extra_buffer" \
  --field "mamba_track_interval=$MAMBA_TRACK_INTERVAL" \
  --field "linear_attn_decode_backend=flashinfer" \
  --field "linear_attn_prefill_backend=flashinfer" \
  --field "ple_offload_embedding=$PLE_OFFLOAD_EMBEDDING" \
  "${PLE_NAMESPACE_ARGS[@]}" \
  --field "qsa_compressed_hicache=true" \
  --field "chunked_prefill_size=$PREFILL_CHUNK_SIZE" \
  --field "target_model_overrides=$TARGET_OVERRIDES" \
  --field "torch_version=$TORCH_VERSION" \
  --field "cuda_arch=12.0")"
export SGLANG_HICACHE_NIXL_BACKEND_STORAGE_DIR="$NIXL_STORAGE"
echo "NIXL FILE namespace: $NIXL_STORAGE"

launch_args=(serve \
  --model-path "$TARGET_MODEL" \
  --model-loader-extra-config "{\"enable_multithread_load\":true,\"num_threads\":${LOADER_THREADS}}" \
  --load-format safetensors \
  --served-model-name pennyroyal \
  --host 0.0.0.0 --port 8001 --tp "$TP_SIZE" \
  --dtype "$COMPUTE_DTYPE" --quantization modelopt_fp4 --kv-cache-dtype "$KV_DTYPE" \
  --mem-fraction-static "${MEM_FRACTION_STATIC}" \
  "${TOKEN_CAP_ARGS[@]}" --warmups=structured_output \
  --context-length "$CONTEXT_LENGTH" --json-model-override-args "$TARGET_OVERRIDES" \
  --page-size "$PAGE_SIZE" --max-running-requests "$MAX_RUNNING_REQUESTS" \
  --chunked-prefill-size "$PREFILL_CHUNK_SIZE" "${PREFILL_ARGS[@]}" \
  --mamba-radix-cache-strategy extra_buffer --mamba-ssm-dtype "$MAMBA_SSM_DTYPE" \
  --max-mamba-cache-size "$MAX_MAMBA_CACHE_SIZE" --gdn-mtp-cache-mode none \
  --linear-attn-decode-backend flashinfer --linear-attn-prefill-backend flashinfer \
  --mamba-track-interval "$MAMBA_TRACK_INTERVAL" \
  "${PLE_ARGS[@]}" --trust-remote-code \
  --chat-template "$CHAT_TEMPLATE" --image-processor-backend "$IMAGE_PROCESSOR_BACKEND" \
  --reasoning-parser qwen3 --tool-call-parser qwen3_coder \
  --enable-request-time-stats-logging --enable-metrics \
  --default-chat-template-kwargs "$DEFAULT_CHAT_TEMPLATE_KWARGS" \
  --speculative-algorithm NEXTN --speculative-num-steps "${SPEC_NUM_STEPS}" \
  --speculative-eagle-topk "${SPEC_EAGLE_TOPK}" --speculative-num-draft-tokens "${SPEC_NUM_DRAFT_TOKENS}" \
  --speculative-draft-model-quantization unquant \
  --speculative-token-map "$TOKEN_MAP" --watchdog-timeout 1800)
if [[ "$WEIGHT_LOADER_DROP_CACHE_AFTER_LOAD" == 1 ]]; then
  launch_args+=(--weight-loader-drop-cache-after-load)
fi
if (( HICACHE_SIZE_GB > 0 )); then
  launch_args+=(--enable-hierarchical-cache --hicache-size "$HICACHE_SIZE_GB" \
    --hicache-host-memory-mode cache --hicache-write-policy write_through \
    --hicache-io-backend kernel --hicache-mem-layout page_first \
    --hicache-storage-backend nixl --hicache-storage-prefetch-policy timeout \
    --hicache-storage-backend-extra-config "@$NIXL_CONFIG")
fi
# These arrays are built above from the operator's tuning knobs. Keep them in
# the actual command line; previously they were only validated and printed,
# so graph limiting, memory saver, and idle sleep had no runtime effect.
launch_args+=("${CUDA_GRAPH_ARGS[@]}" "${SLEEP_ARGS[@]}" "${MFU_ARGS[@]}")
source "$SCRIPT_DIR/startup-summary.sh"
pennyroyal_startup_summary "${launch_args[@]}"
exec "$SGLANG_EXE" "${launch_args[@]}"
