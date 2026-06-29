#!/bin/bash
# Fast pipeline benchmark — runs make_examples + call_variants concurrently.
#
# IMPORTANT: OMP env vars are UNSET before invoking fast_pipeline because
# bp::child() inherits parent env to ALL children. make_examples suffers
# ~10% regression from OMP vars, while call_variants (OneDNN) auto-detects
# nproc when OMP_NUM_THREADS is unset.
#
# CORE PARTITIONING (--partitioned):
# Uses the DV_BIN_PATH trick to inject taskset wrapper scripts. fast_pipeline
# reads DV_BIN_PATH to locate binaries, so we point it at wrapper scripts
# that pin make_examples to one set of cores and call_variants to another.
# This eliminates CPU contention that causes 42% degradation at 16 vCPU.
#
# Usage:
#   bash scripts/benchmark_fast_pipeline.sh [--data-dir /data] [--num-shards 16]
#   bash scripts/benchmark_fast_pipeline.sh --partitioned --me-cores 0-15 --cv-cores 16-31
set -euo pipefail

IMAGE="${IMAGE:-ghcr.io/lambda-biolab/deepvariant-arm64:optimized}"
DATA_DIR="${DATA_DIR:-/data}"
DOCKER_MEM="${DOCKER_MEM:-28g}"
SHM_SIZE="${SHM_SIZE:-4g}"
BATCH_SIZE="${BATCH_SIZE:-256}"
REGION="${REGION:-chr20}"
NUM_SHARDS="${NUM_SHARDS:-$(nproc)}"
NUM_RUNS="${NUM_RUNS:-2}"
ENABLE_BF16="${ENABLE_BF16:-auto}"
USE_ONNX=""
ONNX_MODEL=""
PARTITIONED=""
ME_CORES=""
CV_CORES=""
NO_ONEDNN=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --image) IMAGE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    --docker-mem) DOCKER_MEM="$2"; shift 2 ;;
    --shm-size) SHM_SIZE="$2"; shift 2 ;;
    --batch-size) BATCH_SIZE="$2"; shift 2 ;;
    --num-shards) NUM_SHARDS="$2"; shift 2 ;;
    --num-runs) NUM_RUNS="$2"; shift 2 ;;
    --bf16) ENABLE_BF16="yes"; shift ;;
    --no-bf16) ENABLE_BF16="no"; shift ;;
    --use-onnx) USE_ONNX="true"; shift ;;
    --onnx-model) ONNX_MODEL="$2"; shift 2 ;;
    --partitioned) PARTITIONED="true"; shift ;;
    --me-cores) ME_CORES="$2"; shift 2 ;;
    --cv-cores) CV_CORES="$2"; shift 2 ;;
    --no-onednn) NO_ONEDNN="true"; shift ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

NPROC=$(nproc)
RESULTS_DIR="${DATA_DIR}/benchmark_results"
FLAGS_DIR="${DATA_DIR}/flags"
WRAPPER_DIR="${DATA_DIR}/bin"
mkdir -p "${RESULTS_DIR}" "${FLAGS_DIR}"

# Detect BF16 support
BF16_SUPPORTED="NO"
if grep -q bf16 /proc/cpuinfo 2>/dev/null; then
  BF16_SUPPORTED="YES"
fi

# Resolve BF16 setting
if [[ "${ENABLE_BF16}" == "auto" ]]; then
  ENABLE_BF16="${BF16_SUPPORTED}"
elif [[ "${ENABLE_BF16}" == "yes" ]]; then
  ENABLE_BF16="YES"
else
  ENABLE_BF16="NO"
fi

# Auto-detect core ranges for partitioned mode
if [[ -n "${PARTITIONED}" ]]; then
  HALF=$((NPROC / 2))
  ME_CORES="${ME_CORES:-0-$((HALF - 1))}"
  CV_CORES="${CV_CORES:-${HALF}-$((NPROC - 1))}"
  # Default num_shards to half the cores (one shard per ME core)
  if [[ "${NUM_SHARDS}" == "${NPROC}" ]]; then
    NUM_SHARDS="${HALF}"
  fi
fi

echo "============================================="
echo "  DeepVariant Fast Pipeline Benchmark"
echo "============================================="
echo "Platform: $(uname -m), ${NPROC} vCPUs"
echo "Image: ${IMAGE}"
echo "Region: ${REGION} (full chromosome)"
echo "Shards: ${NUM_SHARDS}"
echo "Batch size: ${BATCH_SIZE}"
echo "BF16 hardware: ${BF16_SUPPORTED}"
echo "BF16 enabled: ${ENABLE_BF16}"
echo "ONNX: ${USE_ONNX:-disabled}"
if [[ -n "${PARTITIONED}" ]]; then
  echo "Partitioned: YES (ME cores: ${ME_CORES}, CV cores: ${CV_CORES})"
else
  echo "Partitioned: NO"
fi
echo "OneDNN: ${NO_ONEDNN:+disabled}${NO_ONEDNN:-enabled}"
echo "Docker mem: ${DOCKER_MEM}, shm: ${SHM_SIZE}"
echo "Runs: ${NUM_RUNS}"
echo ""

# Build call_variants extra args for flag file
CV_EXTRA=""
if [[ -n "${USE_ONNX}" ]]; then
  CV_EXTRA="--use_onnx=true"
  if [[ -n "${ONNX_MODEL}" ]]; then
    CV_EXTRA="${CV_EXTRA}
--onnx_model=${ONNX_MODEL}"
  fi
fi

# Generate flag files
# fast_pipeline auto-appends: --shm_prefix, --shm_buffer_size, --stream_examples, --task=N (to ME)
# fast_pipeline auto-appends: --shm_prefix, --stream_examples, --num_input_shards=N (to CV)
generate_flags() {
  local RUN_NAME="$1"
  local OUT_DIR="${DATA_DIR}/output/${RUN_NAME}"
  mkdir -p "${OUT_DIR}/intermediate"

  cat > "${FLAGS_DIR}/me_flags_${RUN_NAME}.txt" <<EOF
--mode=calling
--ref=/data/reference/GRCh38_no_alt_analysis_set.fasta
--reads=/data/bam/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam
--examples=/data/output/${RUN_NAME}/intermediate/make_examples.tfrecord@${NUM_SHARDS}.gz
--checkpoint=/opt/models/wgs
--regions=${REGION}
EOF

  cat > "${FLAGS_DIR}/cv_flags_${RUN_NAME}.txt" <<EOF
--outfile=/data/output/${RUN_NAME}/intermediate/call_variants_output.tfrecord.gz
--checkpoint=/opt/models/wgs
--batch_size=${BATCH_SIZE}
EOF
  if [[ -n "${CV_EXTRA}" ]]; then
    echo "${CV_EXTRA}" >> "${FLAGS_DIR}/cv_flags_${RUN_NAME}.txt"
  fi

  cat > "${FLAGS_DIR}/pp_flags_${RUN_NAME}.txt" <<EOF
--ref=/data/reference/GRCh38_no_alt_analysis_set.fasta
--infile=/data/output/${RUN_NAME}/intermediate/call_variants_output.tfrecord.gz
--outfile=/data/output/${RUN_NAME}/output.vcf.gz
EOF
}

# Generate wrapper scripts for core partitioning (DV_BIN_PATH trick)
generate_wrappers() {
  local ME_CORES_ARG="$1"
  local CV_CORES_ARG="$2"

  mkdir -p "${WRAPPER_DIR}"

  # make_examples wrapper: pinned to ME cores, no OMP
  cat > "${WRAPPER_DIR}/make_examples" <<WRAPPER
#!/bin/bash
exec taskset -c ${ME_CORES_ARG} /opt/deepvariant/bin/make_examples "\$@"
WRAPPER

  # call_variants wrapper: pinned to CV cores, with OMP for GEMM threading
  local CV_THREAD_COUNT
  # Parse core range to count threads (e.g., "16-31" → 16 threads)
  local CV_START CV_END
  CV_START=$(echo "${CV_CORES_ARG}" | cut -d- -f1)
  CV_END=$(echo "${CV_CORES_ARG}" | cut -d- -f2)
  CV_THREAD_COUNT=$(( CV_END - CV_START + 1 ))

  cat > "${WRAPPER_DIR}/call_variants" <<WRAPPER
#!/bin/bash
export OMP_NUM_THREADS=${CV_THREAD_COUNT}
export OMP_PROC_BIND=false
export OMP_PLACES=cores
exec taskset -c ${CV_CORES_ARG} /opt/deepvariant/bin/call_variants "\$@"
WRAPPER

  # postprocess_variants wrapper: no pinning (runs after ME+CV)
  cat > "${WRAPPER_DIR}/postprocess_variants" <<WRAPPER
#!/bin/bash
exec /opt/deepvariant/bin/postprocess_variants "\$@"
WRAPPER

  chmod +x "${WRAPPER_DIR}/make_examples" "${WRAPPER_DIR}/call_variants" "${WRAPPER_DIR}/postprocess_variants"
  echo "  Wrapper scripts created in ${WRAPPER_DIR}/"
  echo "    make_examples: taskset -c ${ME_CORES_ARG}"
  echo "    call_variants: taskset -c ${CV_CORES_ARG}, OMP_NUM_THREADS=${CV_THREAD_COUNT}"
}

run_fast_pipeline() {
  local RUN_NAME="$1"

  echo ""
  echo ">>> Starting fast_pipeline ${RUN_NAME} ..."
  echo "============================================="

  generate_flags "${RUN_NAME}"

  # Build Docker env args
  local ONEDNN_OPT="1"
  if [[ -n "${NO_ONEDNN}" ]]; then
    ONEDNN_OPT="0"
  fi
  local ENV_ARGS="-e TF_ENABLE_ONEDNN_OPTS=${ONEDNN_OPT} -e CUDA_VISIBLE_DEVICES="
  if [[ "${ENABLE_BF16}" == "YES" ]]; then
    ENV_ARGS="${ENV_ARGS} -e ONEDNN_DEFAULT_FPMATH_MODE=BF16"
  fi

  # Set DV_BIN_PATH: wrapper dir if partitioned, default if not
  if [[ -n "${PARTITIONED}" ]]; then
    generate_wrappers "${ME_CORES}" "${CV_CORES}"
    ENV_ARGS="${ENV_ARGS} -e DV_BIN_PATH=/data/bin"
  else
    ENV_ARGS="${ENV_ARGS} -e DV_BIN_PATH=/opt/deepvariant/bin"
  fi

  WALL_START=$(date +%s)

  # CRITICAL: Override entrypoint to unset OMP vars before fast_pipeline.
  # docker_entrypoint.sh sets OMP_NUM_THREADS, OMP_PROC_BIND, OMP_PLACES.
  # fast_pipeline's bp::child() inherits env to ALL children (make_examples + call_variants).
  # make_examples suffers ~10% regression from OMP vars.
  # call_variants (OneDNN) auto-detects nproc without explicit OMP_NUM_THREADS.
  # With --partitioned, wrapper scripts handle OMP per-process via DV_BIN_PATH trick.
  docker run --rm \
    --memory="${DOCKER_MEM}" \
    --shm-size="${SHM_SIZE}" \
    -v "${DATA_DIR}:/data" \
    ${ENV_ARGS} \
    --entrypoint /bin/bash \
    "${IMAGE}" \
    -c 'unset OMP_NUM_THREADS OMP_PROC_BIND OMP_PLACES KMP_BLOCKTIME && \
      /opt/deepvariant/bin/fast_pipeline \
        --make_example_flags=/data/flags/me_flags_'"${RUN_NAME}"'.txt \
        --call_variants_flags=/data/flags/cv_flags_'"${RUN_NAME}"'.txt \
        --postprocess_variants_flags=/data/flags/pp_flags_'"${RUN_NAME}"'.txt \
        --shm_prefix=dv_'"${RUN_NAME}"' \
        --num_shards='"${NUM_SHARDS}" \
    2>&1 | tee "${RESULTS_DIR}/${RUN_NAME}.log"

  WALL_END=$(date +%s)
  WALL_TIME=$((WALL_END - WALL_START))

  # Extract per-stage timing from log
  ME_TIME=$(grep -oP 'making examples.*?took \K[0-9.]+' "${RESULTS_DIR}/${RUN_NAME}.log" 2>/dev/null || echo "N/A")
  CV_TIME=$(grep -oP 'call_variants.*?took \K[0-9.]+' "${RESULTS_DIR}/${RUN_NAME}.log" 2>/dev/null || echo "N/A")
  PP_TIME=$(grep -oP 'postprocess_variants.*?took \K[0-9.]+' "${RESULTS_DIR}/${RUN_NAME}.log" 2>/dev/null || echo "N/A")

  echo ""
  echo "  ${RUN_NAME} WALL TIME: ${WALL_TIME}s ($(( WALL_TIME / 60 ))m$(( WALL_TIME % 60 ))s)"
  echo "    make_examples:        ${ME_TIME}s"
  echo "    call_variants:        ${CV_TIME}s"
  echo "    postprocess_variants: ${PP_TIME}s"

  cat > "${RESULTS_DIR}/${RUN_NAME}_timing.json" <<JSONEOF
{
  "run": "${RUN_NAME}",
  "pipeline": "fast_pipeline",
  "partitioned": ${PARTITIONED:-false},
  "me_cores": "${ME_CORES}",
  "cv_cores": "${CV_CORES}",
  "region": "${REGION}",
  "batch_size": ${BATCH_SIZE},
  "num_shards": ${NUM_SHARDS},
  "bf16": "${ENABLE_BF16}",
  "use_onnx": ${USE_ONNX:-false},
  "onnx_model": "${ONNX_MODEL}",
  "vcpus": ${NPROC},
  "wall_time_s": ${WALL_TIME},
  "make_examples_s": "${ME_TIME}",
  "call_variants_s": "${CV_TIME}",
  "postprocess_variants_s": "${PP_TIME}"
}
JSONEOF
}

# --- Run benchmarks ---
for i in $(seq 1 "${NUM_RUNS}"); do
  local_prefix="fp"
  if [[ -n "${PARTITIONED}" ]]; then
    local_prefix="fp_part"
  fi
  if [[ -n "${USE_ONNX}" ]]; then
    run_fast_pipeline "${local_prefix}_int8_run${i}"
  elif [[ "${ENABLE_BF16}" == "YES" ]]; then
    run_fast_pipeline "${local_prefix}_bf16_run${i}"
  else
    run_fast_pipeline "${local_prefix}_fp32_run${i}"
  fi
done

# --- Final Summary ---
echo ""
echo ""
echo "============================================="
echo "       FAST PIPELINE BENCHMARK SUMMARY"
echo "============================================="
echo ""
echo "Platform: $(uname -m), ${NPROC} vCPUs"
echo "BF16 hardware: ${BF16_SUPPORTED}"
echo "BF16 enabled: ${ENABLE_BF16}"
echo "ONNX: ${USE_ONNX:-disabled}"
if [[ -n "${PARTITIONED}" ]]; then
  echo "Partitioned: YES (ME: ${ME_CORES}, CV: ${CV_CORES})"
else
  echo "Partitioned: NO"
fi
echo "Region: ${REGION} (full chromosome)"
echo "Shards: ${NUM_SHARDS}"
echo "Batch size: ${BATCH_SIZE}"
echo ""

printf "%-20s  %10s  %14s  %14s  %14s\n" "Run" "Wall(s)" "make_examples" "call_variants" "postprocess"
printf "%-20s  %10s  %14s  %14s  %14s\n" "---" "---" "---" "---" "---"

for i in $(seq 1 "${NUM_RUNS}"); do
  local_prefix="fp"
  if [[ -n "${PARTITIONED}" ]]; then
    local_prefix="fp_part"
  fi
  if [[ -n "${USE_ONNX}" ]]; then
    RUN="${local_prefix}_int8_run${i}"
  elif [[ "${ENABLE_BF16}" == "YES" ]]; then
    RUN="${local_prefix}_bf16_run${i}"
  else
    RUN="${local_prefix}_fp32_run${i}"
  fi
  if [[ -f "${RESULTS_DIR}/${RUN}_timing.json" ]]; then
    WALL=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/${RUN}_timing.json')); print(d['wall_time_s'])")
    ME=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/${RUN}_timing.json')); print(d['make_examples_s'])")
    CV=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/${RUN}_timing.json')); print(d['call_variants_s'])")
    PP=$(python3 -c "import json; d=json.load(open('${RESULTS_DIR}/${RUN}_timing.json')); print(d['postprocess_variants_s'])")
    printf "%-20s  %10ss  %14ss  %14ss  %14ss\n" "${RUN}" "${WALL}" "${ME}" "${CV}" "${PP}"
  fi
done

echo ""
echo "Results saved to: ${RESULTS_DIR}/"
echo "Done."
