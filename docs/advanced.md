# Advanced Usage — DeepVariant Linux ARM64

---

## Quick Start Summary

**Requirements:** ARM64 Linux + Docker. Full WGS needs ~2 GB RAM per CPU core.

```bash
# Add swap if <32 GB RAM (one-time, auto-sized):
curl -fsSL https://raw.githubusercontent.com/lambda-biolab/deepvariant-linux-arm64/main/scripts/setup_swap.sh | sudo bash

docker pull ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1

# Autoconfig: CPU detection, jemalloc, BF16/INT8 selection, parallel CV scaling
docker run \
  -v /path/to/data:/data \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/scripts/run_parallel_cv.sh \
  --model_type=WGS \
  --ref=/data/reference.fasta \
  --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz
```

On NVMe or tmpfs storage, add `--nocompress_intermediates` to skip gzip on TFRecord intermediates (~4% faster ME, ~12 GB disk for chr20).

---

## run_parallel_cv.sh Options

| Flag | Required | Default | Description |
|------|----------|---------|-------------|
| `--model_type` | Yes | — | WGS, WES, PACBIO, ONT_R104, etc. |
| `--ref` | Yes | — | Reference FASTA |
| `--reads` | Yes | — | Input BAM/CRAM |
| `--output_vcf` | Yes | — | Output VCF |
| `--num_shards` | No | nproc | make_examples shards |
| `--num_cv_workers` | No | auto (nproc/8) | Parallel CV workers |
| `--regions` | No | — | Genomic region (e.g., chr20) |
| `--batch_size` | No | 256 | CV batch size |
| `--onnx_model` | No | auto | Custom ONNX model path |
| `--customized_model` | No | — | Custom checkpoint |
| `--sample_name` | No | — | VCF header sample name |
| `--output_gvcf` | No | — | gVCF output path |
| `--postprocess_cpus` | No | num_shards | CPUs for postprocess |
| `--intermediate_results_dir` | No | tmpdir | Working directory |

---

## Manual Backend Override

### BF16 (Graviton3+, 38% faster CV)

```bash
docker run -v /path/to/data:/data \
  -e TF_ENABLE_ONEDNN_OPTS=1 -e ONEDNN_DEFAULT_FPMATH_MODE=BF16 \
  -e OMP_NUM_THREADS=$(nproc) -e OMP_PROC_BIND=false -e OMP_PLACES=cores \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/bin/run_deepvariant \
  --model_type=WGS --ref=/data/reference.fasta --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz --num_shards=$(nproc) \
  --call_variants_extra_args="--batch_size=256"
```

### Custom INT8 Quantization (WES, PacBio, or your own calibration data)

The Docker image ships with a pre-quantized WGS INT8 model. To quantize a different model:

```bash
# Step 1: Run the pipeline to generate calibration TFRecords
docker run -v /path/to/data:/data \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/bin/run_deepvariant \
  --model_type=WGS --ref=/data/reference.fasta --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz --num_shards=$(nproc) \
  --intermediate_results_dir=/data/intermediate

# Step 2: Quantize (one-time, ~2 min)
docker run -v /path/to/data:/data \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  quantize_model \
  --input /opt/models/wgs/model.onnx \
  --output /data/model_int8_custom.onnx \
  --tfrecord_dir /data/intermediate/make_examples \
  --saved_model_dir /opt/models/wgs

# Step 3: Use the custom INT8 model
docker run -v /path/to/data:/data \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/bin/run_deepvariant \
  --model_type=WGS --ref=/data/reference.fasta --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz --num_shards=$(nproc) \
  --call_variants_extra_args="--batch_size=256,--use_onnx=true,--onnx_model=/data/model_int8_custom.onnx"
```

### Sequential Mode (simpler, no parallel CV)

```bash
docker run -v /path/to/data:/data \
  -e DV_AUTOCONFIG=1 -e DV_USE_JEMALLOC=1 \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/bin/run_deepvariant \
  --model_type=WGS --ref=/data/reference.fasta --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz --num_shards=$(nproc) \
  --call_variants_extra_args="--batch_size=256"
```

---

## Deploy on ARM64

### Fresh Instance Setup

```bash
# One-command setup: installs Docker, detects BF16 support, configures TF env vars
bash scripts/setup_graviton.sh
```

Works on Ubuntu 22.04/24.04. Installs Docker, build essentials, and writes CPU-specific TF environment variables to `/etc/profile.d/deepvariant-arm64.sh`.

### Pull the Docker Image

```bash
# Authenticate (if using a private registry)
echo "$GITHUB_PAT" | docker login ghcr.io -u USERNAME --password-stdin

# Pull (~2-4 GB compressed)
docker pull ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1
```

### Platform-Specific Notes

| Platform | Key setting | Why |
|----------|------------|-----|
| **Graviton3/4** (c7g, c8g) | Autoconfig enables BF16 + OneDNN (>=48 GB RAM) | BF16 BFMMLA — 38% faster CV. <48 GB falls back to INT8 ONNX (TF OOMs) |
| **Oracle A1** (Altra, Neoverse-N1) | Autoconfig selects INT8 ONNX, disables OneDNN | OneDNN+ACL adds 29% ME overhead on N1 without BF16 |
| **Oracle A2** (AmpereOne) | Autoconfig blocks OneDNN (SIGILL), selects INT8 ONNX | ACL compiled for N1 crashes on AmpereOne ISA — both ME and CV |
| **Hetzner CAX** (shared Altra) | Same as Oracle A1 | Shared vCPU; ~5% throttling variance |

`DV_AUTOCONFIG=1` handles all of the above automatically. You only need manual env vars if you want to override the defaults.

---

## Workflow Integration

Nextflow and Snakemake workflows are provided in [`workflows/`](../workflows/):

```bash
# Nextflow (single sample)
nextflow run workflows/nextflow/main.nf \
  -profile arm64 \
  --bam /data/sample.bam --ref /data/GRCh38.fasta --outdir results/

# Nextflow (batch — CSV with columns: sample,bam,bai)
nextflow run workflows/nextflow/main.nf \
  -profile arm64 \
  --input samples.csv --ref /data/GRCh38.fasta --outdir results/

# Snakemake
snakemake --cores 16 \
  --config bam=/data/sample.bam ref=/data/GRCh38.fasta
```

Platform profiles: `arm64` (auto-detect), `graviton`, `oracle_a1`, `hetzner`. See [workflows/nextflow/nextflow.config](../workflows/nextflow/nextflow.config) for details.

---

## Reproduce These Results

### 1. Download Test Data

```bash
sudo mkdir -p /data/{reference,bam,truth,output}
sudo chown -R $(whoami) /data

# Reference genome
wget -q -O /data/reference/GRCh38_no_alt_analysis_set.fasta.gz \
  https://storage.googleapis.com/genomics-public-data/references/GRCh38/GCA_000001405.15_GRCh38_no_alt_analysis_set.fna.gz
gunzip /data/reference/GRCh38_no_alt_analysis_set.fasta.gz
samtools faidx /data/reference/GRCh38_no_alt_analysis_set.fasta

# HG003 chr20 BAM + GIAB truth set
BUCKET=https://storage.googleapis.com/deepvariant/case-study-testdata
wget -q -P /data/bam/ ${BUCKET}/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam
wget -q -P /data/bam/ ${BUCKET}/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam.bai
wget -q -P /data/truth/ ${BUCKET}/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz
wget -q -P /data/truth/ ${BUCKET}/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz.tbi
wget -q -P /data/truth/ ${BUCKET}/HG003_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed
```

### 2. Run the Pipeline on chr20

```bash
docker run \
  -v /data:/data \
  -e DV_AUTOCONFIG=1 -e DV_USE_JEMALLOC=1 \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/bin/run_deepvariant \
  --model_type=WGS \
  --ref=/data/reference/GRCh38_no_alt_analysis_set.fasta \
  --reads=/data/bam/HG003.novaseq.pcr-free.35x.dedup.grch38_no_alt.chr20.bam \
  --output_vcf=/data/output/HG003.chr20.vcf.gz \
  --regions chr20 \
  --num_shards=$(nproc) \
  --intermediate_results_dir=/data/output/intermediate \
  --call_variants_extra_args="--batch_size=256"
```

### 3. Validate with hap.py

```bash
bash scripts/validate_accuracy.sh \
  --vcf /data/output/HG003.chr20.vcf.gz \
  --truth-vcf /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  --truth-bed /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed \
  --ref /data/reference/GRCh38_no_alt_analysis_set.fasta \
  --output-dir /data/output/happy_results
```

This pulls the hap.py Docker image (`jmcdani20/hap.py:v0.3.12`) automatically and checks against accuracy gates. Expected output:

```
  SNP F1:   0.9978  (gate: >= 0.9974)   PASS
  INDEL F1: 0.9962  (gate: >= 0.9940)   PASS
```

Or use the all-in-one benchmark script:

```bash
bash scripts/benchmark_full_chr20.sh --data-dir /data
```

---

## Build from Source

**Prerequisites:** ARM64 Linux (Ubuntu 24.04, GCC 13+), 16 GB RAM + 8 GB swap, ~50 GB disk, Python 3.10.

```bash
git clone https://github.com/lambda-biolab/deepvariant-linux-arm64.git
cd deepvariant-linux-arm64

cat > user.bazelrc << 'EOF'
build --jobs 4
build --local_ram_resources=12288
build --cxxopt=-include --cxxopt=cstdint
build --host_cxxopt=-include --host_cxxopt=cstdint
EOF

chmod +x build-prereq-arm64.sh build_release_binaries_arm64.sh
./build-prereq-arm64.sh
source settings_arm64.sh
./build_release_binaries_arm64.sh
docker build -f Dockerfile.arm64.runtime -t deepvariant-arm64 .
```

Full build: several hours on an 8-core machine (~2273 Bazel actions).

---

## What Was Changed

**New files:** `Dockerfile.arm64`, `Dockerfile.arm64.runtime`, `settings_arm64.sh`, `build-prereq-arm64.sh`, `build_release_binaries_arm64.sh`, `scripts/` (benchmarking, quantization, parallel CV, autoconfig, jemalloc ablation), and `workflows/` (Nextflow + Snakemake integration).

**Key modifications to upstream:** `third_party/htslib.BUILD` (NEON detection), `third_party/libssw.BUILD` (sse2neon), `tools/build_absl.sh` (clang-14), `run-prereq.sh` (Ubuntu 24.04), `deepvariant/call_variants.py` (ONNX inference, INT8 renormalization, SavedModel warmup). ACL v23.08 SVE filter and OneDNN indirect GEMM patches for AmpereOne preserved in `third_party/` for source rebuilds.

### Build Fixes

| Issue | Fix |
|-------|-----|
| SSE4.1/POPCNT not supported | Runtime `uname -m` detection in htslib genrule |
| `sse2neon.h` undeclared | Added to `hdrs` in `libssw.BUILD` |
| `uint64_t` undeclared (GCC 13) | `--cxxopt=-include --cxxopt=cstdint` |
| `clang-11` not found (Ubuntu 24.04) | Updated to `clang-14` |
| Missing Boost libraries | Added to `build-prereq-arm64.sh` |
| GLIBC 2.38 mismatch | `arm64v8/ubuntu:24.04` Docker base |
| Python 3.10 not in repos | deadsnakes PPA |
| OOM during build | `user.bazelrc` with `--jobs 4` |

### Dead Ends (Documented)

| Approach | Result | Why it failed |
|----------|--------|--------------|
| EfficientNet-B3 model swap | 3x slower despite 3.2x fewer FLOPs | Depthwise conv poor GEMM density on CPU — see [TRAINING_EXPERIMENT.md](../TRAINING_EXPERIMENT.md) |
| KMP_AFFINITY tuning | 30% regression | Conflicts with OMP thread pinning on ARM |
| ONNX ACL ExecutionProvider | Fragile, 16 ops supported | Not worth maintaining |
| Dynamic INT8 on ARM64 | Crash | ConvInteger op missing in ORT ARM64 |
| fast_pipeline at 16 vCPU | 42% slower | CPU contention between ME and CV |
| INT8 beyond 16 threads | No improvement | GEMM saturates — use parallel CV instead |
| ONNX inter-op parallelism | No improvement | InceptionV3 is intra-op bound |

---

## Operational Pitfalls (Docker + Cloud Instances)

| Issue | Impact | Fix |
|-------|--------|-----|
| **Docker output files owned by root** | Benchmark scripts with `rm -rf` crash on re-runs | `sudo chown -R ubuntu:ubuntu /data/output/` before re-running, or run Docker with `--user $(id -u):$(id -g)` |
| **Repacking `.zip` Python apps breaks `.so` files** | call_variants crashes with "invalid ELF header" | Never repack zip-based Python apps; copy entire `.zip` from a working image |
| **`/data/` dirs missing on fresh instance** | Benchmark scripts crash at `mkdir -p` if parent is root-owned | Create with `sudo mkdir -p /data/{flags,output,...} && sudo chown -R ubuntu:ubuntu /data` |
| **GCS reference download fails with `curl -sO`** | Returns XML error page | Use `wget -q` instead of `curl -sO` for GCS public data |
| **`--memory` Docker flag: do NOT hardcode 28g** | OOM-kills make_examples on <32 GB machines | Omit `--memory` for ONNX backend. For TF backend: set to 90% of actual RAM |
| **Docker entrypoint sets OMP vars** | Leaks to all children in fast_pipeline | Override entrypoint with `--entrypoint /bin/bash` and unset OMP vars |
| **ghcr.io pull requires auth** | `docker pull` fails on fresh instances | Run `echo "$PAT" \| docker login ghcr.io -u USERNAME --password-stdin` first |
| **GCS reference genome URL changed** | `genomics-public-data` returns 404 | Use `deepvariant/case-study-testdata` bucket instead |
| **Docker image ONNX model is FP32, not INT8** | Using wrong model gives 2x slower CV | Always pass `--onnx_model=/data/model_int8_static.onnx` for INT8 |
| **postprocess missing `--regions` with parallel CV** | Produces ~125 RefCall variants instead of 207,799 | Always pass `--regions` and `--small_model_cvo_records` |
| **fresh instance setup failures** | Silent errors waste time | Monitor setup scripts for first 5 min — most failures happen in first 60s |

> **Important:** When spinning up new cloud instances and running setup scripts (Docker install, data download, image pull), check for errors every 60 seconds for the first 5 minutes. Many failures (wrong URLs, auth issues, permission errors) happen within the first minute — waiting 10+ minutes before checking wastes time and money.

---

## Roadmap

- [x] Native ARM64 build + Docker image
- [x] GIAB HG003 chr20 accuracy validation
- [x] BF16 inference on Graviton3+ (38% CV speedup)
- [x] INT8 static quantization (2.3x speedup, zero accuracy loss, 74% smaller model)
- [x] Parallel call_variants wrapper (1.9-2.5x CV speedup)
- [x] jemalloc integration (14-17% make_examples speedup)
- [x] Autoconfig for CPU detection
- [x] Hetzner CAX41 full WGS validation ($0.12/genome measured, 5h16m)
- [x] Full 30x WGS end-to-end validation — INT8 ONNX, all chromosomes (SNP F1=0.9961, INDEL F1=0.9956, 2h17m on Graviton4)
- [x] WES model validation on ARM64 — INT8 ONNX, IDT exome 100x (SNP F1=0.9931, INDEL F1=0.9738)
- [x] Nextflow / Snakemake integration with platform profiles
- [ ] Edge device validation (Jetson, RK3588)

> For long-read ONT or PacBio data, see [Clair3](https://github.com/HKU-BAL/Clair3).
