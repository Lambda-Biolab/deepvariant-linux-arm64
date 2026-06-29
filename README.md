# DeepVariant — Linux ARM64 Native Build

[![CI](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/ci.yml/badge.svg)](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/ci.yml)
[![ARM64 Build & Test](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/arm64-build.yml/badge.svg)](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/arm64-build.yml)
[![CodeQL](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/codeql.yaml/badge.svg)](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/actions/workflows/codeql.yaml)
[![Dependabot](https://img.shields.io/badge/dependabot-active-blue?logo=dependabot)](https://github.com/Lambda-Biolab/deepvariant-linux-arm64/network/updates)
[![release](https://img.shields.io/badge/base-v1.10.0-green?logo=github)](https://github.com/google/deepvariant/releases)
[![platform](https://img.shields.io/badge/platform-Linux%20ARM64-blue?logo=linux)](https://en.wikipedia.org/wiki/AArch64)
[![accuracy](https://img.shields.io/badge/SNP%20F1-0.9961%20(full%20genome)-success)](docs/accuracy.md)
[![license](https://img.shields.io/badge/license-BSD--3-blue)](#license)

> Fork of [google/deepvariant](https://github.com/google/deepvariant) v1.10.0. Tags: `v{upstream}-arm64.{n}`.

**The gold standard in variant calling. Now on ARM64. For less than the price of a chewing gum per genome.**

Google's [DeepVariant](https://rdcu.be/7Dhl) (Poplin et al., *Nature Biotechnology* 2018) achieves the highest SNP accuracy of any open-source variant caller. This fork brings it to Linux ARM64 — run it on a $0.16/hr Oracle A1 instance and get near-reference accuracy at **$0.80/genome** — or **$0.12/genome on Hetzner CAX41**. At UK Biobank scale (490,640 genomes), that's a **$2.3 million compute cost difference** vs. the x86 reference — enough to fund ~4,600 additional genomes. For population-scale GWAS where cost dominates, this is a viable alternative.

---

## Quick Start

**Requirements:** ARM64 Linux + Docker. Full WGS needs ~2 GB RAM per CPU core.

```bash
# Add swap if <32 GB RAM (one-time, auto-sized):
curl -fsSL https://raw.githubusercontent.com/lambda-biolab/deepvariant-linux-arm64/main/scripts/setup_swap.sh | sudo bash

docker pull ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1

docker run \
  -v /path/to/data:/data \
  ghcr.io/lambda-biolab/deepvariant-arm64:v1.10.0-arm64.1 \
  /opt/deepvariant/scripts/run_parallel_cv.sh \
  --model_type=WGS \
  --ref=/data/reference.fasta \
  --reads=/data/input.bam \
  --output_vcf=/data/output.vcf.gz
```

The script auto-detects your CPU (Graviton3/4, AmpereOne, Neoverse-N1/N2), enables jemalloc, selects the right backend (BF16 or INT8 ONNX), and scales parallel CV workers to your CPU and RAM. No env vars needed — just `docker run`. User-provided env vars always take precedence.

---

## Key Features

- **INT8 quantization without accuracy loss** — InceptionV3 CNN quantized to INT8 via ONNX Runtime static quantization. 74% smaller model (21 MB), 2.3x faster inference than FP32 ONNX. Stratified GIAB validation confirms INT8 matches or exceeds BF16 across all regions — homopolymers, tandem repeats, segmental duplications included. [Accuracy details →](docs/accuracy.md)

- **BF16 on Graviton3+** — 38% call_variants speedup with zero accuracy loss via `ONEDNN_DEFAULT_FPMATH_MODE=BF16`. Benchmarked on c7g.4xlarge at 0.232 s/100 inference rate.

- **Parallel call_variants** — Breaks through the GEMM saturation ceiling by splitting inference across N independent ONNX workers. 1.7-2.5x CV speedup with zero code changes. Only works with ONNX backend (~3 GB/worker vs TF's ~26 GB).

- **First open-source Linux ARM64 port** — Builds on AWS Graviton3/4, Oracle A1/A2, Hetzner CAX, and any ARM64 Linux. Patches 8 upstream ARM64/GCC 13 compilation errors. BSD-3 licensed.

- **Systematic ARM64 benchmarking corpus** — 5 platforms × 3 backends × jemalloc on/off × 16/32 vCPU, all accuracy-validated at each point. [Benchmark details →](docs/benchmarks.md)

- **Nextflow / Snakemake integration** — Platform profiles for arm64, graviton, oracle_a1, hetzner. Single sample and batch CSV input. See [`workflows/`](workflows/).

---

## Documentation

- [Benchmarks](docs/benchmarks.md) — Platform comparisons, cost projections, parallel CV speedups, profiling data, platform-specific notes
- [Accuracy Validation](docs/accuracy.md) — Full genome and WES GIAB validation, stratified regions, accuracy gates
- [Advanced Usage](docs/advanced.md) — Backend configuration, all Docker commands, parallel CV setup, build from source, known pitfalls, roadmap

---

## How to Cite

> Poplin, R. et al. A universal SNP and small-indel variant caller using deep neural networks. *Nature Biotechnology* **36**, 983-987 (2018). https://rdcu.be/7Dhl

## License

[BSD-3-Clause](LICENSE). Not an official Google product. Not validated for clinical use.
