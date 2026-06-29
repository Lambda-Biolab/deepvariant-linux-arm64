# Benchmarks — DeepVariant Linux ARM64

> **⚠️ These benchmarks were measured on DeepVariant v1.9.0.** The v1.10.0 merge introduces continuous phasing, fuzzy channels, and Keras 3 small models that may affect performance. Re-benchmarking is in progress. The v1.10.0 chr20 functional test passed (207,799 variants, matching v1.9.0 baseline).

All benchmarks: GIAB HG003 Illumina NovaSeq PCR-free 35x WGS, full chr20 (63 Mbp), GRCh38 no-alt reference. Accuracy validated with `rtg vcfeval` against GIAB v4.2.1 truth set. WGS extrapolation: `chr20_wall × 48.1` (~15-20% uncertainty).

---

## Platform Overview

| Platform | Instance | Microarch | vCPUs | RAM | $/hr |
|----------|----------|-----------|-------|-----|------|
| AWS Graviton3 | c7g.4xlarge | Neoverse V1 | 16 | 32 GB | $0.58 |
| AWS Graviton3 | c7g.8xlarge | Neoverse V1 | 32 | 64 GB | $1.15 |
| AWS Graviton4 | c8g.4xlarge | Neoverse V2 | 16 | 32 GB | $0.68 |
| AWS Graviton4 | c8g.8xlarge | Neoverse V2 | 32 | 64 GB | $1.36 |
| Oracle A1 | A1.Flex (16 OCPU) | Altra (Neoverse N1) | 16 | 32 GB | $0.16 |
| Oracle A2 | A2.Flex (16 OCPU) | AmpereOne (Siryn) | 32 | 64 GB | $0.64 |
| Hetzner CAX41 | CAX41 | Altra (Neoverse N1) | 16 (shared) | 32 GB | $0.043 |

---

## Cost at Scale

| Study scale | x86 reference ($5.01) | Oracle A1 ($0.80) | Hetzner ($0.12) | Savings vs. x86 |
|-------------|----------------------|-------------------|-----------------|-----------------|
| 1 genome | $5.01 | $0.80 | $0.12 | — |
| 1,000 genomes | $5,010 | $800 | $120 | up to $4,890 |
| 100,000 genomes (large GWAS) | $501,000 | $80,000 | $12,000 | up to $489,000 |
| 490,640 genomes ([UK Biobank WGS](https://doi.org/10.1038/s41586-025-09272-9)) | $2,458,106 | $392,512 | $58,877 | up to $2,399,229 |
| 3,000,000 genomes ([Three Million African Genomes](https://doi.org/10.1038/d41586-021-00313-7)) | $15,030,000 | $2,400,000 | $360,000 | up to $14,670,000 |

> **On Hetzner scale-out:** Default account limit is 5 servers, expandable to 10-25 per project on request. Hetzner is not designed for hyperscale burst compute. For runs requiring 50+ concurrent instances, Oracle A1 ($0.80/genome) is the operationally practical choice. The Hetzner figure is most relevant for individual researchers and small labs doing serial or small-batch processing. Shared vCPU wall time varies with neighbor load — $0.12 is measured for a single full WGS run (5h16m at $0.022/hr).

---

## Compared to Alternatives

| Solution | $/genome | Speed (30x WGS) | Accuracy (SNP F1) | License | ARM64 |
|----------|----------|-----------------|-------------------|---------|-------|
| Google DeepVariant (96 vCPU x86) | ~$5.01 | ~1.3 hr | ~0.9996 | Open source | No |
| Google DeepVariant (n1-standard-16, preemptible) | ~$2.84 | ~5.5 hr | ~0.9996 | Open source | No |
| Sentieon DNAscope (OCI ARM) | <$1 + license | ~1-2 hr | Comparable | Proprietary | Yes |
| Sentieon DNAscope (AWS Graviton, spot) | ~$0.74 + license | ~1-2 hr | Comparable | Proprietary | Yes |
| NVIDIA Parabricks | <$2 + license | 8-16 min | Comparable | Proprietary | No |
| **This fork — Oracle A1, 4-way CV** | **$0.80** | **~5.0 hr** | **0.9961*** | **Open source** | **Yes** |
| **This fork — Hetzner CAX41, INT8** | **$0.12** | **5h16m** | **0.9961*** | **Open source** | **Yes** |

> *Full 30x WGS accuracy (all chromosomes, INT8 ONNX), validated on both Graviton4 (c8g.8xlarge) and Hetzner CAX41 — identical F1 scores across platforms. chr20-only is higher (0.9978) due to chr20 being among the easier chromosomes. The 0.0035 gap vs x86 (0.9961 vs ~0.9996) corresponds to ~17K additional missed SNPs genome-wide — clinically irrelevant for most GWAS/population studies, but worth noting for clinical diagnostics.

The trade-off is wall time and a small accuracy gap. A Hetzner run takes ~5 hours vs. ~1 hour on a 96-vCPU x86 instance, with SNP F1 0.35% lower than the x86 reference. For batch processing, overnight pipelines, and cost-constrained studies, this is an acceptable trade-off. For clinical turnaround or maximum accuracy, use GPU-accelerated DeepVariant on x86.

---

## Inference Rate by Platform

| Platform | vCPUs | Config | CV Rate | chr20 Wall |
|----------|-------|--------|---------|-----------|
| GCP t2a (Neoverse-N1) | 8 | FP32 | 0.880 s/100 | 12m57s |
| GCP t2a (Neoverse-N1) | 16 | FP32 | 0.512 s/100 | 7m22s |
| AWS Graviton3 | 16 | FP32 | 0.379 s/100 | 9m41s |
| **AWS Graviton3** | **16** | **BF16** | **0.232 s/100** | **8m06s** |
| **AWS Graviton3** | **16** | **INT8 ONNX** | **0.237 s/100** | **~8m27s** |
| **AWS Graviton4** | **16** | **INT8 ONNX** | **0.197 s/100** | **6m06s** |
| AWS Graviton4 | 16 | ONNX FP32 | 0.446 s/100 | 10m02s |
| **Oracle A2 (AmpereOne)** | **16 OCPU** | **INT8 ONNX** | **0.389 s/100** | **9m44s** |
| **Oracle A1 (Altra)** | **16 OCPU** | **INT8 ONNX** | **0.309 s/100** | **~8m29s** |
| Oracle A1 (Altra) | 16 OCPU | TF Eigen FP32 | 0.588 s/100 | 12m15s |
| **Hetzner CAX41 (Altra)** | **16 (shared)** | **INT8 ONNX** | **0.366 s/100** | **~8m45s** |

---

## Full Pipeline — 16 vCPU, Best Backend

| Platform | Backend | jemalloc | ME | CV | PP | Total | $/hr | $/genome | N |
|----------|---------|----------|-----|-----|-----|-------|------|----------|---|
| Graviton3 (c7g) | BF16 | on | 242s | 188s | 9s | **443s** | $0.58 | **$3.43** | 2* |
| Graviton3 (c7g) | INT8 ONNX | off | 299s | 194s | 14s | **507s** | $0.58 | **$3.92** | 3 |
| **Graviton4 (c8g)** | **INT8 ONNX** | **off** | **194s** | **158s** | **6s** | **366s** | **$0.68** | **$3.33** | 2* |
| **Oracle A2 (AmpereOne)** | **INT8 ONNX** | **on** | **210s** | **318s** | **12s** | **544s** | **$0.32** | **$2.32** | **4** |
| **Oracle A1 (Altra)** | **INT8 ONNX** | **on** | **219s** | **250s** | **14s** | **486s** | **$0.16** | **$1.04** | 3 |
| **Hetzner CAX41 (Altra)** | **INT8 ONNX** | **on** | **253s** | **298s** | **17s** | **578s** | **$0.043** | **$0.33** | 1 |

> *N<4; wider confidence interval. Hetzner: ~5% throttling variance. All $/genome: `chr20_wall_s × 48.1 / 3600 × $/hr`. Oracle A2 pricing: $0.04/OCPU/hr — 16-vCPU rows use 8 OCPU ($0.32/hr). INT8 ONNX is the only working backend on A2 (OneDNN SIGILL). jemalloc via `-e DV_USE_JEMALLOC=1`.

---

## Full Pipeline — 32 vCPU, Sequential

| Platform | Backend | jemalloc | ME | CV | PP | Total | $/hr | $/genome | N |
|----------|---------|----------|-----|-----|-----|-------|------|----------|---|
| Graviton3 (c7g.8xlarge) | BF16 | on | 131s | 141s | 8s | **283s** | $1.15 | **$4.35** | 2* |
| **Graviton4 (c8g.8xlarge)** | **BF16** | **on** | **100s** | **126s** | **5s** | **232s** | **$1.36** | **$4.22** | 2* |
| Graviton4 (c8g.8xlarge) | INT8 ONNX | on | 96s | 129s | 5s | **233s** | $1.36 | **$4.24** | 2* |

> **Key insight at 32 vCPU:** BF16 and INT8 converge (~232-233s on Graviton4) because both hit the CV floor. CV rate doesn't improve beyond 16 ORT threads. ME scales well (2x shards → 1.8x speedup) but CV is the bottleneck. Solution: parallel call_variants.

---

## Parallel call_variants

At 16+ threads, InceptionV3 GEMM saturates and more threads yield no speedup. `run_parallel_cv.sh` launches N independent ONNX workers on disjoint shards, giving 1.7-2.5x CV speedup with **zero changes to DeepVariant code**. Variant counts match sequential baseline exactly (207,799).

| Platform | vCPU | Sequential CV | 4-way CV | Speedup | $/genome | N |
|----------|------|--------------|----------|---------|----------|---|
| **Oracle A1** (16 OCPU) | 16 | 250s | **147s** | **1.70x** | **$0.80** | 3 |
| **Graviton4** (c8g.8xlarge) | 32 | 128s | **61s** | **2.10x** | **~$3.13** | 3 |
| **Graviton3** (c7g.8xlarge) | 32 | 141s | **74s** | **1.90x** | **~$3.35** | 4 |
| **Oracle A2** (16 OCPU) | 32 | 283s | **114s** | **2.47x** | **~$2.14** | 2* |

> ONNX backend only (~3 GB/worker). TF SavedModel uses ~26 GB RSS per worker — use ONNX or 64+ GB instances for TF. Projected full pipeline (measured CV + sequential ME/PP). Graviton4 wall ~172s, Graviton3 ~218s, Oracle A1 376s (measured).

---

## jemalloc Impact

| Platform | N | ME Delta | CV Delta | Wall Delta |
|----------|---|----------|----------|------------|
| Graviton3 (c7g) | 2 | -13.8% | +1.6% (noise) | -9.0% (487→443s) |
| Oracle A2 (AmpereOne) | 4 | -17.0% | within noise | -6.9% (584→544s) |
| Oracle A1 (Altra/N1) | 3-4 | -10.6% | within noise | -4.5% (509→486s) |

ME improvement is the dominant factor. jemalloc's per-thread arenas reduce malloc contention in make_examples' C++ allocations. CV sees minimal benefit because ONNX Runtime and TF have their own internal allocators.

---

## Cumulative Performance Optimization History

| Optimization | Impact | Status |
|-------------|--------|--------|
| C++ opts (haplotype cap, flat buffer, query cache) | ME -10% | Done |
| TF warmup (dummy inference pass) | CV -4% | Done |
| BF16 on Graviton3+ | **CV -38% (1.61x)** | Done |
| INT8 static quantization (ONNX) | 2.3x over ONNX FP32 | Done |
| OMP env scoping (per-subprocess) | ME 307→299s (2.6%) | Done |
| jemalloc (`DV_USE_JEMALLOC=1`) | **ME -14-17%, wall -7-9%** | Verified |
| **Parallel call_variants (4-way)** | **CV 2.0-2.5x faster** | Done |
| ONNX inter-op parallelism | No improvement | Tested/rejected |
| KMP_AFFINITY + system allocator | **30% regression** | Reverted |
| ~~EfficientNet-B3~~ | **3x slower** | Dead end |

---

## Profiling: make_examples CPU Breakdown

Measured via `perf stat -a` and `perf record -a` on Graviton3 (c7g.8xlarge, 32 vCPU, 16 shards, chr20). See `scripts/profile_make_examples.sh`.

### Graviton3 (Neoverse V1, OneDNN+ACL)

**Hardware counters:**

| Metric | glibc (default) | jemalloc | Delta |
|--------|----------------|----------|-------|
| Wall time | 237s | 205s | **-13.5%** |
| IPC (insn/cycle) | 2.61 | 2.77 | +6.1% |
| L1-dcache miss rate | 0.92% | 0.79% | -14.1% |
| Cache ref miss rate | 0.93% | 0.80% | -14.0% |
| Branch misprediction | 1.28% | 1.31% | +2.3% |

**DSO-level CPU breakdown:**

| DSO | Default | jemalloc | Category |
|-----|---------|----------|----------|
| `_message.so` (protobuf upb) | **29.4%** | 28.9% | Protobuf serialization |
| `libtensorflow_cc.so.2` | **24.8%** | 25.7% | TF small model inference |
| `libc.so.6` | **18.1%** | **4.4%** | malloc/free + libc |
| `python3.10` | 9.8% | 10.3% | Python interpreter |
| `libz.so.1.3` | **7.9%** | 8.2% | gzip (TFRecord compression) |
| `libtensorflow_framework.so.2` | 3.5% | 3.7% | TF framework |
| `[kernel.kallsyms]` | 3.1% | **9.4%** | Kernel (syscalls, page faults) |
| `libjemalloc.so.2` | — | **4.7%** | jemalloc allocator |
| `libstdc++.so.6` | 1.3% | 0.8% | C++ STL |
| Other | ~2.1% | ~3.9% | numpy, pywrap_tf, ld-linux |

### Oracle A2 (AmpereOne, Eigen fallback)

Measured with `TF_ENABLE_ONEDNN_OPTS=0` (OneDNN+ACL causes SIGILL on AmpereOne).

**Hardware counters:**

| Metric | glibc (default) | jemalloc | Delta |
|--------|----------------|----------|-------|
| Wall time | 256.1s | 200.5s | **-21.7%** |
| IPC (insn/cycle) | 1.72 | 1.77 | +2.9% |
| L1-dcache miss rate | 1.16% | 0.92% | **-20.7%** |
| Cache ref miss rate | 1.16% | 0.92% | **-20.7%** |
| Branch misprediction | 1.62% | 1.75% | +8.0% |

**DSO-level CPU breakdown:**

| DSO | Default | jemalloc | Category |
|-----|---------|----------|----------|
| `_message.so` (protobuf upb) | **42.6%** | 49.7% | Protobuf serialization |
| `libc.so.6` | **23.2%** | **4.9%** | malloc/free + libc |
| `python3.10` | 13.2% | 15.5% | Python interpreter |
| `libz.so.1.3` | 9.7% | 11.3% | gzip (TFRecord compression) |
| `libtensorflow_cc.so.2` | 2.9% | 3.6% | TF Eigen inference (no OneDNN) |
| `libtensorflow_framework.so.2` | 2.6% | 2.8% | TF framework |
| `libstdc++.so.6` | 2.2% | 1.3% | C++ STL |
| `[kernel.kallsyms]` | 1.1% | 1.4% | Kernel |
| `libjemalloc.so.2` | — | **6.5%** | jemalloc allocator |
| Other | ~2.5% | ~3.0% | pywrap_tf, numpy, ld-linux |

### Cross-Platform Comparison (Graviton3 vs Oracle A2)

| Metric | Graviton3 (Neoverse V1) | Oracle A2 (AmpereOne) | Significance |
|--------|------------------------|----------------------|--------------|
| IPC (default) | **2.61** | 1.72 | G3 has 52% higher IPC — better out-of-order execution |
| IPC (jemalloc) | **2.73** | 1.77 | jemalloc IPC gain: G3 +4.6%, A2 +2.9% |
| L1 miss (default) | **0.92%** | 1.16% | A2 has 26% higher L1 miss rate |
| L1 miss (jemalloc) | **0.78%** | 0.92% | jemalloc reduces: G3 -15%, A2 -21% |
| `libc.so.6` share (default) | 18.1% | **23.2%** | A2 has 28% higher malloc share |
| `libc.so.6` share (jemalloc) | 4.4% | 4.9% | Both converge to ~5% with jemalloc |
| `_message.so` share | 29.4% | **42.6%** | Protobuf dominates more on A2 |
| TF inference share | **24.8%** | 5.5% | G3 OneDNN+ACL compute-dense; A2 Eigen lightweight |
| Wall time (default) | **237s** | 256.1s | G3 is 7.5% faster |
| Wall time (jemalloc) | **212s** | 200.5s | A2 catches up with jemalloc |

### Key Findings

1. **Protobuf serialization is the #1 hotspot (29.4%).** `_message.so` (Google's upb C protobuf library) dominates. On macOS, Instruments attributed this to calling functions (pileup/realigner). The real cost is proto creation/serialization for Read, Example, and Variant protos.

2. **TF small model inference is #2 (24.8%).** The WGS small model (CNN for candidate filtering, added in v1.9.0) runs during make_examples. On non-WGS models without small model, this ~25% would shift to pileup/realigner.

3. **malloc/free is 18.1% (matches macOS).** With jemalloc: `libc.so.6` drops from 18.1% → 4.4%, `libjemalloc.so.2` adds 4.7%, net reduction ~9% absolute. jemalloc's per-thread arenas reduce L1 cache misses by 15% and increase IPC by 4.6% — it's better memory locality, not just faster malloc.

4. **Oracle A2's malloc contention is 28% higher than Graviton3** (23.2% vs 18.1% of cycles in `libc.so.6`). This explains why jemalloc's wall time improvement is ~2x larger on A2 (21.7% vs 10.7%).

5. **AmpereOne IPC (1.72) is 34% lower than Graviton3 (2.61).** The Eigen code paths produce more memory-bound stalls. This IPC gap is the primary reason A2 is slower despite having the same vCPU count.

---

## Recommended Configurations

| Use Case | Platform | vCPU | Backend | Parallel CV | $/genome |
|----------|----------|------|---------|-------------|----------|
| **Cheapest overall** | Hetzner CAX41 | 16 (shared) | INT8 ONNX+jemalloc | no | **$0.33** |
| Cheapest (dedicated) | Oracle A1 (16 OCPU) | 16 | INT8 ONNX+jemalloc | 4-way | **$0.80** |
| Cheapest (sequential) | Oracle A1 (16 OCPU) | 16 | INT8 ONNX+jemalloc | no | **$1.04** |
| Best speed/cost | Graviton4 (c8g.8xlarge) | 32 | BF16+jemalloc | 4-way | **~$3.13** |
| Fastest ARM64 | Graviton4 (c8g.8xlarge) | 32 | BF16+jemalloc | 4-way | **~$3.13** |

---

## Platform-Specific Notes

- **Hetzner CAX41 (Neoverse N1):** $0.33/genome sequential INT8 ONNX + jemalloc. Same N1 as Oracle A1 but 3.7x cheaper per hour. Shared vCPU introduces ~6% CV rate variance. OneDNN OFF on N1 — adds 29% ME overhead without BF16.
- **Oracle A1 (Altra/N1):** $0.80/genome with 4-way parallel CV. No BF16 or i8mm — use INT8 ONNX with jemalloc. Higher run-to-run variance (sigma=14s sequential). See `docs/oracle-a1-benchmark.md`.
- **Graviton3/4:** Use BF16 when `grep bf16 /proc/cpuinfo` is present. INT8 ONNX is fallback. Both achieve similar CV rates on Graviton3.
- **Oracle A2 (AmpereOne):** OneDNN+ACL causes SIGILL (compiled for Neoverse-N1). INT8 ONNX is the fastest working backend. Entrypoint auto-forces OneDNN off.
- **Graviton4 BF16:** Full TF pipeline OOM-killed on 32 GB machines (TF ~26 GB RSS). Use INT8 ONNX on 32 GB instances, or upgrade to 64 GB.

---

## What Was Tried and Didn't Work

| Approach | Result | Details |
|----------|--------|---------|
| EfficientNet-B3 model swap | 3x slower | Depthwise separable convs have poor GEMM density on CPU |
| MobileNetV2 / depthwise-separable models | Dead end | Same architecture class, same penalty |
| KMP_AFFINITY tuning | 30% regression | `granularity=core,compact,1,0` + system allocator |
| ONNX ACL ExecutionProvider | Not worth it | 16 supported ops, fragile builds, no pre-built wheels |
| Dynamic INT8 on ARM64 | Broken | ConvInteger(10) op not in ORT ARM64 CPUExecutionProvider |
| fast_pipeline at 16 vCPU | 42% slower | CPU contention between concurrent ME+CV |
| fast_pipeline on Oracle A2 32 vCPU | <1% improvement | PP broken on CVO ordering |
| INT8 ONNX beyond 16 threads | No scaling | 0.358 s/100 at both 16 and 32 ORT threads |
| ONNX inter-op parallelism | No improvement | InceptionV3 is intra-op GEMM bound |
| ONNX FP32 on AmpereOne | 1.96x slower than TF Eigen | 0.759 vs 0.387 s/100 |
| TF SavedModel on 32 GB | OOM kill | ~26 GB RSS, forking PP pushes >32 GB |
