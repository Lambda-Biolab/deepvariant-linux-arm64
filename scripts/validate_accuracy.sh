#!/bin/bash
set -euo pipefail

# Validate DeepVariant ARM64 VCF accuracy against GIAB truth set using rtg vcfeval.
#
# Reason: hap.py has no ARM64 build (Python 2.7 + Boost + x86 SIMD flags).
# hap.py --engine=vcfeval delegates to rtg vcfeval internally anyway.
# rtg-tools is Java-based and runs natively on any architecture.
#
# Usage:
#   bash scripts/validate_accuracy.sh \
#     --vcf output.vcf.gz \
#     --truth-vcf HG003_truth.vcf.gz \
#     --truth-bed HG003_truth.bed \
#     --ref GRCh38.chr20.fasta \
#     --output-dir results/
#
# Targets (from Google's published DeepVariant v1.9.0 numbers):
#   SNP F1   >= 0.9995
#   INDEL F1 >= 0.9945

RTG_VERSION="${RTG_VERSION:-3.12.1}"

VCF=""
TRUTH_VCF=""
TRUTH_BED=""
REF=""
OUTPUT_DIR="./rtg_results"

while [[ $# -gt 0 ]]; do
  case $1 in
    --vcf) VCF="$2"; shift 2 ;;
    --truth-vcf) TRUTH_VCF="$2"; shift 2 ;;
    --truth-bed) TRUTH_BED="$2"; shift 2 ;;
    --ref) REF="$2"; shift 2 ;;
    --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

if [[ -z "${VCF}" || -z "${TRUTH_VCF}" || -z "${TRUTH_BED}" || -z "${REF}" ]]; then
  echo "ERROR: All of --vcf, --truth-vcf, --truth-bed, --ref are required."
  exit 1
fi

mkdir -p "${OUTPUT_DIR}"

echo "========== Accuracy Validation =========="
echo "VCF:       ${VCF}"
echo "Truth VCF: ${TRUTH_VCF}"
echo "Truth BED: ${TRUTH_BED}"
echo "Reference: ${REF}"
echo "Output:    ${OUTPUT_DIR}"
echo ""

# ---------------------------------------------------------------------------
# Install rtg-tools if not already present
# Reason: the upstream `rtg` shell wrapper rejects non-x86_64 arches.
# We invoke the JAR directly via a wrapper function to bypass that check.
# ---------------------------------------------------------------------------
if command -v rtg &>/dev/null && rtg version &>/dev/null; then
  rtg_cmd() { rtg "$@"; }
  echo "Using system rtg-tools"
else
  echo "========== Installing rtg-tools ${RTG_VERSION}"
  RTG_URL="https://github.com/RealTimeGenomics/rtg-tools/releases/download/${RTG_VERSION}/rtg-tools-${RTG_VERSION}-nojre.zip"
  RTG_TMP=$(mktemp -d)
  wget -q "${RTG_URL}" -O "${RTG_TMP}/rtg-tools.zip"
  unzip -q "${RTG_TMP}/rtg-tools.zip" -d "${RTG_TMP}"
  RTG_DIR="${RTG_TMP}/rtg-tools-${RTG_VERSION}"
  RTG_JAR="${RTG_DIR}/RTG.jar"
  rm "${RTG_TMP}/rtg-tools.zip"
  echo "rtg-tools installed to ${RTG_DIR}"

  # Reason: upstream rtg wrapper checks uname -m for x86_64 and exits on ARM64.
  # The JAR itself is pure Java and runs on any architecture.
  rtg_cmd() { java -jar "${RTG_JAR}" "$@"; }
fi

echo "rtg version: $(rtg_cmd version 2>&1 | head -1)"
echo ""

# ---------------------------------------------------------------------------
# Prepare SDF reference (rtg vcfeval requires SDF format, not FASTA)
# ---------------------------------------------------------------------------
SDF_DIR="${OUTPUT_DIR}/ref.sdf"
if [[ ! -d "${SDF_DIR}" ]]; then
  echo "========== Converting reference to SDF format"
  rtg_cmd format -o "${SDF_DIR}" "${REF}"
  echo ""
fi

# ---------------------------------------------------------------------------
# Run rtg vcfeval
# ---------------------------------------------------------------------------
EVAL_DIR="${OUTPUT_DIR}/vcfeval"
rm -rf "${EVAL_DIR}"

echo "========== Running rtg vcfeval"
rtg_cmd vcfeval \
  --baseline="${TRUTH_VCF}" \
  --calls="${VCF}" \
  --evaluation-regions="${TRUTH_BED}" \
  --template="${SDF_DIR}" \
  --output="${EVAL_DIR}" \
  --threads="$(nproc)"

echo ""
echo "========== Results =========="

# ---------------------------------------------------------------------------
# Parse rtg vcfeval summary.txt
# Reason: rtg vcfeval summary.txt format:
#   Threshold  True-pos-baseline  True-pos-call  False-pos  False-neg  Precision  Sensitivity  F-measure
#   None       12345              12345          12        34         0.9990     0.9970       0.9980
# with separate sections for SNP and non-SNP when --squash-ploidy is not used.
# ---------------------------------------------------------------------------
SUMMARY="${EVAL_DIR}/summary.txt"
if [[ -f "${SUMMARY}" ]]; then
  echo ""
  echo "--- rtg vcfeval Summary ---"
  cat "${SUMMARY}"

  echo ""
  echo "--- F1 Score Check ---"

  # Extract F1 (F-measure) from the summary for SNP and non-SNP rows
  SNP_F1=$(awk '/^SNP/{print $NF}' "${SUMMARY}" | tail -1)
  INDEL_F1=$(awk '/^non-SNP/{print $NF}' "${SUMMARY}" | tail -1)

  echo "SNP F1:   ${SNP_F1:-N/A}"
  echo "INDEL F1: ${INDEL_F1:-N/A}"

  # Check against targets
  PASS=true
  if [[ -n "${SNP_F1}" ]]; then
    if (( $(echo "${SNP_F1} < 0.9995" | bc -l) )); then
      echo "WARNING: SNP F1 ${SNP_F1} is below target 0.9995"
      PASS=false
    else
      echo "SNP F1 PASS (>= 0.9995)"
    fi
  fi

  if [[ -n "${INDEL_F1}" ]]; then
    if (( $(echo "${INDEL_F1} < 0.9945" | bc -l) )); then
      echo "WARNING: INDEL F1 ${INDEL_F1} is below target 0.9945"
      PASS=false
    else
      echo "INDEL F1 PASS (>= 0.9945)"
    fi
  fi

  if [[ "${PASS}" == "true" ]]; then
    echo ""
    echo "VALIDATION PASSED: ARM64 build meets accuracy targets."
  else
    echo ""
    echo "VALIDATION FAILED: ARM64 build does not meet accuracy targets."
    exit 1
  fi
else
  echo "ERROR: rtg vcfeval summary file not found at ${SUMMARY}"
  exit 1
fi
