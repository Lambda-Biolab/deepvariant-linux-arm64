# Accuracy Validation — DeepVariant Linux ARM64

> **⚠️ Accuracy results measured on DeepVariant v1.9.0.** v1.10.0 accuracy validation is in progress.

All results validated with `rtg vcfeval` against GIAB HG003 v4.2.1 truth set.

---

## Full Genome Validation (30x WGS)

**HG003, GRCh38, all chromosomes.** Validated on two independent platforms with identical F1 scores:

| Metric | Precision | Recall | F1 | TP | FP | FN |
|--------|-----------|--------|------|--------|-------|--------|
| **SNP** | 0.9986 | 0.9936 | **0.9961** | 3,307,188 | 4,616 | 21,397 |
| **INDEL** | 0.9973 | 0.9938 | **0.9956** | 501,294 | 1,333 | 3,126 |
| **Overall** | 0.9984 | 0.9936 | **0.9960** | 3,808,482 | 5,949 | 24,523 |

Validated on:
- **AWS c8g.8xlarge** (32 vCPU Graviton4, INT8 ONNX + jemalloc): **2h17m**, $3.10
- **Hetzner CAX41** (16 shared vCPU Neoverse-N1, INT8 ONNX + jemalloc + 6 GB swap): **5h16m**, $0.12

Both platforms produce identical F1 scores (SNP 0.9961, INDEL 0.9956). TP/FP/FN counts differ by <0.04% due to thread-count-dependent floating-point accumulation in ONNX inference.

---

## WES (Exome) Validation

**HG003 IDT exome 100x** (all chromosomes, IDT capture kit) on Graviton4 (c8g.8xlarge). INT8 model quantized from the WES-specific SavedModel using 500 calibration samples (Percentile 99.99).

| Metric | FP32 BF16 | INT8 ONNX | Delta |
|--------|-----------|-----------|-------|
| **SNP F1** | 0.9930 | **0.9931** | +0.0001 |
| **INDEL F1** | 0.9776 | **0.9738** | -0.0038 |
| **Overall F1** | 0.9924 | **0.9923** | -0.0001 |

INT8 CV rate: **0.120 s/100** (24% faster than FP32 BF16 at 0.149 s/100). Total pipeline: **3m34s** (INT8) vs **3m55s** (FP32). Variant counts match exactly: 47,895.

---

## INT8 Quantization — Accuracy Assessment

Post-training INT8 quantization typically degrades accuracy by 0.6-3% on vision CNNs. DeepVariant's InceptionV3 is unusually quantization-friendly — its large, dense convolutions avoid the depthwise layers that cause INT8 degradation in other architectures.

| Metric | FP32 (chr20) | BF16 (chr20) | INT8 ONNX (chr20) | INT8 Full Genome | INT8 WES |
|--------|------|------|-----------|------------------|----------|
| **SNP F1** | 0.9977 | 0.9977 | **0.9978** | **0.9961** | **0.9931** |
| **INDEL F1** | 0.9961 | 0.9961 | **0.9962** | **0.9956** | **0.9738** |

> chr20 results: GIAB HG003 v4.2.1, `rtg vcfeval` (all rows). Full Genome: 30x WGS HG003, all chromosomes, on AWS c8g.8xlarge. WES: HG003 IDT exome 100x, all chromosomes.

**Note on full-genome accuracy:** The INT8 full genome SNP F1 (0.9961) is lower than both the chr20 result (0.9978) and the x86 reference (~0.9996). The chr20→full genome drop is expected (harder chromosomes contribute more errors), but the gap vs x86 (0.0035 SNP F1) likely reflects differences in the ARM64 build environment (TF version, OneDNN backend, numerical precision paths) rather than INT8 quantization per se — the chr20 INT8 result *matches or exceeds* FP32 and BF16 on the same ARM64 platform.

---

## Stratified Region Validation

INT8 matches or exceeds BF16 in every GIAB stratification region — including segmental duplications, where it actually *improves* by 0.006 SNP F1:

| Region | INT8 SNP F1 | BF16 SNP F1 | INT8 INDEL F1 | BF16 INDEL F1 |
|--------|-------------|-------------|---------------|---------------|
| Aggregate chr20 | 0.9978 | 0.9977 | 0.9962 | 0.9961 |
| Homopolymers (>=7bp) | 0.9985 | 0.9985 | 0.9967 | 0.9963 |
| Simple Repeats | 0.9994 | 0.9994 | 0.9967 | 0.9961 |
| Tandem Repeats (201-10,000bp) | 0.9983 | 0.9983 | 0.9926 | 0.9926 |
| Segmental Duplications | **0.9802** | 0.9744 | 0.9814 | 0.9814 |

No localized degradation detected in any region. Production caveat cleared.

---

## Accuracy Gates (chr20)

| Metric | Target | Gate | Status |
|--------|--------|------|--------|
| **SNP F1** | 0.9978 | >= 0.9974 | PASS |
| **INDEL F1** | 0.9962 | >= 0.9940 | PASS |

Validation via `scripts/validate_accuracy.sh`:

```bash
bash scripts/validate_accuracy.sh \
  --vcf /data/output/HG003.chr20.vcf.gz \
  --truth-vcf /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark.vcf.gz \
  --truth-bed /data/truth/HG003_GRCh38_1_22_v4.2.1_benchmark_noinconsistent.bed \
  --ref /data/reference/GRCh38_no_alt_analysis_set.fasta \
  --output-dir /data/output/happy_results
```

Expected output:

```
  SNP F1:   0.9978  (gate: >= 0.9974)   PASS
  INDEL F1: 0.9962  (gate: >= 0.9940)   PASS
```

> These are chr20-only numbers. Full genome accuracy is lower (SNP F1=0.9961, INDEL F1=0.9956) — see Full Genome Validation above.

---

## Engineering Notes

- **INT8 renormalization:** INT8 quantization can produce probability vectors that don't sum to 1.0. Without correction, `postprocess_variants` crashes with `ValueError: Invalid genotype likelihoods`. The ONNX inference path in this fork renormalizes outputs (`predictions / row_sums`) before passing to `round_gls()`. This fix is mandatory and is included in the Docker image.
- **BF16 vs INT8 accuracy:** On chr20, both backends produce near-identical results (SNP F1 0.9977-0.9978, INDEL F1 0.9961-0.9962). The choice between them should be based on platform BF16 support and operational convenience, not accuracy.
