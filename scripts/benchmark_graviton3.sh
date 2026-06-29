#!/bin/bash
# Benchmark DeepVariant on AWS Graviton3 (c7g) with BF16 fast math.
#
# Prerequisites:
#   - AWS c7g.4xlarge instance (16 vCPU Graviton3, Neoverse V1 with BF16)
#   - Docker installed
#   - DeepVariant ARM64 image pulled from ghcr.io
#
# Usage:
#   bash scripts/benchmark_graviton3.sh [--image IMAGE] [--data-dir DIR]
#
# This script:
#   1. Verifies BF16 hardware capability
#   2. Checks OneDNN+ACL is active (go/no-go gate)
#   3. Runs thread count sweep to find optimal config
#   4. Runs full chr20:1-30M benchmark with best thread count
#   5. Compares FP32 vs BF16 performance
set -euo pipefail

# --- Configuration ---
IMAGE="${IMAGE:-ghcr.io/lambda-biolab/deepvariant-arm64:optimized}"
DATA_DIR="${DATA_DIR:-/data}"
REGION="chr20:1-30000000"
BATCH_SIZE=256
# Auto-detect: use 90% of available RAM. Hardcoding 28g OOM-kills on <32 GB machines.
DOCKER_MEM="$(( $(free -g | awk '/^Mem:/{print $2}') * 90 / 100 ))g"

# Parse CLI args
while [[ $# -gt 0 ]]; do
  case $1 in
    --image) IMAGE="$2"; shift 2 ;;
    --data-dir) DATA_DIR="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 1 ;;
  esac
done

echo "=== DeepVariant Graviton3 BF16 Benchmark ==="
echo "Image: ${IMAGE}"
echo "Data dir: ${DATA_DIR}"
echo "Region: ${REGION}"
echo "Batch size: ${BATCH_SIZE}"
echo ""

# --- Step 1: Verify BF16 hardware capability ---
echo ">>> [1/5] Checking BF16 hardware support..."
if grep -q bf16 /proc/cpuinfo 2>/dev/null; then
  echo "  BF16 supported (Graviton3+/Neoverse V1+)"
else
  echo "  WARNING: BF16 NOT detected in /proc/cpuinfo."
  echo "  This instance may not be Graviton3+. BF16 benchmarks will have no effect."
  echo "  Continuing with FP32-only benchmark..."
fi

NPROC=$(nproc)
echo "  CPUs: ${NPROC}"
echo "  Architecture: $(uname -m)"
echo ""

# --- Step 2: Verify OneDNN+ACL is active (go/no-go gate) ---
echo ">>> [2/5] Verifying OneDNN+ACL backend activation..."
echo "  Running DNNL_VERBOSE=1 test (this takes ~30 seconds)..."

ACL_COUNT=$(docker run --rm \
  --memory="${DOCKER_MEM}" \
  -v "${DATA_DIR}:/data" \
  -e DNNL_VERBOSE=1 \
  -e TF_ENABLE_ONEDNN_OPTS=1 \
  -e CUDA_VISIBLE_DEVICES="" \
  "${IMAGE}" \
  python3 -c "
import os
os.environ['TF_CPP_MIN_LOG_LEVEL'] = '0'
import tensorflow as tf
import numpy as np

# Load model and run one inference to trigger kernel selection
model = tf.saved_model.load('/opt/models/wgs')
infer = model.signatures['serving_default']
x = tf.constant(np.zeros([1, 100, 221, 7], dtype=np.float32))
_ = infer(x)
" 2>&1 | grep -ci "acl" || echo "0")

echo "  ACL kernel references in DNNL_VERBOSE output: ${ACL_COUNT}"
if [[ "${ACL_COUNT}" -eq 0 ]]; then
  echo ""
  echo "  *** GO/NO-GO: FAIL ***"
  echo "  OneDNN is NOT using ACL kernels. BF16 env var will be silently ignored."
  echo "  Investigate TF build configuration before proceeding with BF16 benchmarks."
  echo "  Common causes:"
  echo "    - TF wheel built without ACL support"
  echo "    - OneDNN falling back to 'ref' or 'cpp' implementations"
  echo "  Run: DNNL_VERBOSE=1 ... 2>&1 | head -50  to see kernel implementations"
  echo ""
  echo "  Continuing with FP32-only benchmark (BF16 results will be meaningless)..."
  ACL_ACTIVE=false
else
  echo "  *** GO/NO-GO: PASS *** — ACL kernels active."
  ACL_ACTIVE=true
fi
echo ""

# --- Step 3: Thread count sweep ---
echo ">>> [3/5] Thread count sweep (finding optimal OMP_NUM_THREADS)..."
echo "  Testing with a quick 5000-example run at batch_size=${BATCH_SIZE}..."

BEST_THREADS=0
BEST_TIME=99999

for THREADS in 8 12 ${NPROC}; do
  if [[ ${THREADS} -gt ${NPROC} ]]; then
    continue
  fi

  for PROC_BIND in false close; do
    echo ""
    echo "  --- OMP_NUM_THREADS=${THREADS}, OMP_PROC_BIND=${PROC_BIND} ---"

    START=$(date +%s%N)
    docker run --rm \
      --memory="${DOCKER_MEM}" \
      -v "${DATA_DIR}:/data" \
      -e TF_ENABLE_ONEDNN_OPTS=1 \
      -e ONEDNN_DEFAULT_FPMATH_MODE=BF16 \
      -e OMP_NUM_THREADS="${THREADS}" \
      -e OMP_PROC_BIND="${PROC_BIND}" \
      -e OMP_PLACES=cores \
      -e CUDA_VISIBLE_DEVICES="" \
      "${IMAGE}" \
      /opt/deepvariant/bin/call_variants \
        --outfile=/dev/null \
        --examples="/data/output/examples/examples.tfrecord@32.gz" \
        --checkpoint=/opt/models/wgs \
        --batch_size="${BATCH_SIZE}" \
      2>&1 | tail -5
    END=$(date +%s%N)

    ELAPSED_MS=$(( (END - START) / 1000000 ))
    echo "  Elapsed: ${ELAPSED_MS}ms"

    if [[ ${ELAPSED_MS} -lt ${BEST_TIME} ]]; then
      BEST_TIME=${ELAPSED_MS}
      BEST_THREADS=${THREADS}
      BEST_BIND=${PROC_BIND}
    fi
  done
done

echo ""
echo "  Best config: OMP_NUM_THREADS=${BEST_THREADS}, OMP_PROC_BIND=${BEST_BIND}"
echo "  Best time: ${BEST_TIME}ms"
echo ""

# --- Step 4: Full benchmark — FP32 baseline ---
echo ">>> [4/5] Full chr20:1-30M benchmark (FP32 baseline)..."
echo "  OMP_NUM_THREADS=${BEST_THREADS}, batch_size=${BATCH_SIZE}"

FP32_START=$(date +%s)
docker run --rm \
  --memory="${DOCKER_MEM}" \
  -v "${DATA_DIR}:/data" \
  -e TF_ENABLE_ONEDNN_OPTS=1 \
  -e OMP_NUM_THREADS="${BEST_THREADS}" \
  -e OMP_PROC_BIND="${BEST_BIND}" \
  -e OMP_PLACES=cores \
  -e CUDA_VISIBLE_DEVICES="" \
  "${IMAGE}" \
  /opt/deepvariant/bin/run_deepvariant \
    --model_type=WGS \
    --ref=/data/reference/GRCh38_no_alt_analysis_set.fasta \
    --reads=/data/bam/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam \
    --output_vcf=/data/output/benchmark_fp32.vcf.gz \
    --regions="${REGION}" \
    --num_shards="${BEST_THREADS}" \
    --intermediate_results_dir=/data/output/intermediate_fp32 \
    --call_variants_extra_args="--batch_size=${BATCH_SIZE}" \
  2>&1 | tee /data/output/benchmark_fp32.log
FP32_END=$(date +%s)
FP32_TOTAL=$((FP32_END - FP32_START))
echo ""
echo "  FP32 total wall time: ${FP32_TOTAL}s ($(( FP32_TOTAL / 60 ))m$(( FP32_TOTAL % 60 ))s)"
echo ""

# --- Step 5: Full benchmark — BF16 ---
echo ">>> [5/5] Full chr20:1-30M benchmark (BF16)..."
echo "  OMP_NUM_THREADS=${BEST_THREADS}, ONEDNN_DEFAULT_FPMATH_MODE=BF16"

BF16_START=$(date +%s)
docker run --rm \
  --memory="${DOCKER_MEM}" \
  -v "${DATA_DIR}:/data" \
  -e TF_ENABLE_ONEDNN_OPTS=1 \
  -e ONEDNN_DEFAULT_FPMATH_MODE=BF16 \
  -e OMP_NUM_THREADS="${BEST_THREADS}" \
  -e OMP_PROC_BIND="${BEST_BIND}" \
  -e OMP_PLACES=cores \
  -e CUDA_VISIBLE_DEVICES="" \
  "${IMAGE}" \
  /opt/deepvariant/bin/run_deepvariant \
    --model_type=WGS \
    --ref=/data/reference/GRCh38_no_alt_analysis_set.fasta \
    --reads=/data/bam/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam \
    --output_vcf=/data/output/benchmark_bf16.vcf.gz \
    --regions="${REGION}" \
    --num_shards="${BEST_THREADS}" \
    --intermediate_results_dir=/data/output/intermediate_bf16 \
    --call_variants_extra_args="--batch_size=${BATCH_SIZE}" \
  2>&1 | tee /data/output/benchmark_bf16.log
BF16_END=$(date +%s)
BF16_TOTAL=$((BF16_END - BF16_START))
echo ""
echo "  BF16 total wall time: ${BF16_TOTAL}s ($(( BF16_TOTAL / 60 ))m$(( BF16_TOTAL % 60 ))s)"
echo ""

# --- Summary ---
echo "==========================================="
echo "          BENCHMARK SUMMARY"
echo "==========================================="
echo ""
echo "Platform: $(uname -m), $(nproc) vCPUs"
echo "BF16 hardware: $(grep -q bf16 /proc/cpuinfo 2>/dev/null && echo 'YES' || echo 'NO')"
echo "ACL active: ${ACL_ACTIVE}"
echo "Best thread config: OMP_NUM_THREADS=${BEST_THREADS}, OMP_PROC_BIND=${BEST_BIND}"
echo "Batch size: ${BATCH_SIZE}"
echo "Region: ${REGION}"
echo ""
echo "FP32 wall time: ${FP32_TOTAL}s ($(( FP32_TOTAL / 60 ))m$(( FP32_TOTAL % 60 ))s)"
echo "BF16 wall time: ${BF16_TOTAL}s ($(( BF16_TOTAL / 60 ))m$(( BF16_TOTAL % 60 ))s)"
if [[ ${FP32_TOTAL} -gt 0 ]]; then
  SPEEDUP=$(echo "scale=2; ${FP32_TOTAL} / ${BF16_TOTAL}" | bc)
  PERCENT=$(echo "scale=1; (1 - ${BF16_TOTAL} / ${FP32_TOTAL}) * 100" | bc)
  echo "BF16 speedup: ${SPEEDUP}x (${PERCENT}% faster)"
fi
echo ""
echo "VCF outputs:"
echo "  FP32: /data/output/benchmark_fp32.vcf.gz"
echo "  BF16: /data/output/benchmark_bf16.vcf.gz"
echo ""
echo "Next step: Run hap.py on both VCFs to confirm zero accuracy impact:"
echo "  docker run -v ${DATA_DIR}:/data jmcdani20/hap.py:v0.3.12 /opt/hap.py/bin/hap.py \\"
echo "    /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \\"
echo "    /data/output/benchmark_bf16.vcf.gz \\"
echo "    -f /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed \\"
echo "    -r /data/reference/GRCh38_no_alt_analysis_set.fasta \\"
echo "    -o /data/output/happy_bf16 \\"
echo "    --engine=vcfeval"
