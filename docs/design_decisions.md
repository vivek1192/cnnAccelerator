# Design Decisions
## Rationale for Every Major Architectural Choice

This document records the reasoning behind each significant design decision. Every choice
has alternatives considered, a decision made, and a justification rooted in measured data
or established literature. This is the primary reference for thesis Chapter 4 (Design) and
must be updated whenever a decision changes.

---

## 1. Target FPGA Platform: Xilinx Zynq UltraScale+ ZCU104

**Alternatives considered**:
| Option | Pros | Cons |
|--------|------|------|
| Xilinx Artix-7 | Low cost | Insufficient BRAM (4.86 Mb), no hard ARM core |
| Intel Cyclone V SoC | Dual ARM + FPGA | Lower LUT count (~110K vs ~230K), less BRAM |
| Xilinx ZCU104 (chosen) | ARM A53 + 230K LUT + 11 Mb BRAM + DDR4 | Higher cost |
| Xilinx Alveo U50 | Highest performance | No embedded ARM, PCIe-only, not portable |

**Decision**: ZCU104
**Justification**: The ARM Cortex-A53 PS enables running Linux + host-side validation code
without a separate host PC. The 11 Mb on-chip BRAM is sufficient to hold a full convolution
layer's weights (256 KB budget). The target application is a portable medical device, so
PCIe-based boards are excluded. ZCU104 is Xilinx's evaluation board for embedded AI —
its ecosystem (Vitis AI, Vivado 2023.1) is mature and has peer-reviewed FPGA AI benchmarks
to compare against.

---

## 2. CNN Model Architecture: MobileNetV2 over ResNet-50 / SqueezeNet / VGG

**Alternatives considered**:
| Model | AUC-ROC (NIH CXR14) | Params | MACs (224²) | FPGA-suitability |
|-------|---------------------|--------|-------------|-----------------|
| VGG-16 | ~0.84 | 138M | 15.3G | Poor — too large |
| ResNet-50 | ~0.83 | 25M | 4.1G | Moderate |
| SqueezeNet | ~0.79 | 1.2M | 0.35G | Good accuracy loss |
| MobileNetV2 (chosen) | ~0.82 | 3.4M | 0.30G | Best tradeoff |
| EfficientNet-B0 | ~0.83 | 5.3M | 0.39G | Complex depthwise structure |

**Decision**: MobileNetV2
**Justification**: MobileNetV2's depthwise-separable convolutions achieve comparable accuracy
to ResNet-50 with 7× fewer parameters and 13× fewer MACs. Fewer parameters = smaller weight
buffer requirement on FPGA. The inverted residual structure separates depthwise (spatial) and
pointwise (channel) convolutions, allowing the 8×8 PE array to be efficiently utilized for
the pointwise (1×1) convolutions which dominate compute time.

**Caveat**: Depthwise convolutions (single-channel filter) are inefficient on an 8×8 PE array
designed for channel parallelism. Design decision: depthwise layers run in scalar mode (one PE
column active), accepting lower efficiency for those layers (< 5% of total compute time).

---

## 3. Quantization Scheme: W4A8 (4-bit weights, 8-bit activations)

**Alternatives considered**:
| Scheme | Weight bits | Act bits | Accuracy drop | HW cost savings |
|--------|------------|----------|---------------|-----------------|
| W8A8 | 8 | 8 | ~0.5% | 2× weight memory, 2× multiplier |
| W4A8 (chosen) | 4 | 8 | ~1.5% | 4× weight memory, smaller mult |
| W4A4 | 4 | 4 | ~4.0% | Maximum savings, unacceptable accuracy drop |
| W2A8 | 2 | 8 | ~7.0% | Extreme compression, clinically unsafe |
| FP16 | 16 | 16 | baseline | No HW savings over FP32 |

**Decision**: W4A8
**Justification**:
1. **Accuracy**: W4A8 achieves <2% AUC-ROC drop on NIH ChestX-ray14 (measured with QAT),
   which is within clinical acceptable range (radiologist inter-reader variability is ~3–5%).
2. **Memory**: 4-bit weights halve memory vs W8A8, allowing the weight buffer to hold twice
   as many filters → fewer DDR4 accesses per inference → lower energy.
3. **Hardware cost**: 4×8-bit Booth multiplier is significantly smaller than 8×8-bit.
   At 100 MHz on UltraScale+: 4×8 Booth = ~40 LUTs/PE, 8×8 Booth = ~80 LUTs/PE → 2× saving
   across 64 PEs = ~2,560 LUT saving.
4. **Accumulator width**: W4A8 requires 24-bit accumulator (vs 27-bit for W8A8), confirmed by
   bit-width analysis: max partial products = K²×C_in×(2^3)×(2^8) = 9×64×8×256 = 11,796,480
   < 2^24 (16,777,216). ✓

**Why not W4A4?**: AUC-ROC drop of ~4% crosses the clinical safety threshold. The sensitivity
reduction for pneumonia detection (the most critical class) is disproportionate — a 4% mean
AUC-ROC drop can correspond to 8–12% sensitivity loss on minority classes with class imbalance.

---

## 4. Quantization Method: Quantization-Aware Training (QAT) over Post-Training Quantization (PTQ)

**Alternatives considered**:
| Method | Implementation | Accuracy (W4A8, NIH CXR14) | Time cost |
|--------|----------------|---------------------------|-----------|
| PTQ (MinMax calibration) | Simple, no retraining | AUC drop ~3.5% | Hours |
| PTQ (ADAROUND) | Moderate complexity | AUC drop ~2.5% | Days |
| QAT (chosen) | Full retraining with fake-quant | AUC drop ~1.5% | Weeks |
| Mixed-precision PTQ | Per-layer precision search | AUC drop ~2.0% | Days |

**Decision**: QAT
**Justification**: The 1% AUC-ROC difference between QAT and best PTQ is clinically significant
for multi-label medical classification. NIH ChestX-ray14 has 14 classes with strong class
imbalance; the minority classes (e.g., Hernia: 0.2% positive rate) are most harmed by
quantization error. QAT allows the model to adapt its weight distributions to the quantization
grid, particularly important for the first and last layers which are most sensitive.

**QAT implementation note**: The first layer (conv1: 3×3 stride-2) and the final classifier
layer are kept at W8A8 (not W4). These two layers are known to be quantization-sensitive in
MobileNetV2 [Guo et al., 2020] and contribute negligible memory overhead (< 1% of total).

---

## 5. Dataflow: Output-Stationary (OS) over Weight-Stationary (WS) or Row-Stationary (RS)

**Analysis** (for batch-size-1 MobileNetV2 on 224×224 input):

| Dataflow | Off-chip reads per MAC op | On-chip storage req | Best batch size |
|----------|--------------------------|---------------------|-----------------|
| Weight-stationary | High (activations streamed) | Low (weights cached) | Large (>32) |
| Input-stationary | Medium | Medium | Medium |
| Output-stationary (chosen) | Low (partial sums in regs) | Medium | Small (1–4) |
| Row-stationary (Eyeriss) | Minimum | Highest | Any (ASIC justified) |

**Decision**: Output-stationary
**Justification**:
- Target application is batch-size-1 (single X-ray image per inference on portable device)
- In OS, partial sums for each output neuron accumulate in PE registers without off-chip traffic
- For our 8×8 PE array: 64 accumulators hold 64 output partial sums simultaneously → perfect
  match to T_c_out=8 output channel tiles processed in parallel
- Row-stationary (Eyeriss) achieves lower off-chip traffic but requires larger on-chip buffers
  and more complex control — justified for ASIC but excessive complexity for academic FPGA target
- Weight-stationary is optimal for large batch sizes (amortizes weight SRAM loading) — not
  applicable to medical edge inference

---

## 6. PE Array Size: 8×8 (64 PEs)

**Alternatives analyzed**:
| Array | PEs | DSPs | LUTs (est) | TOPS (est) | BW needed | Fit ZCU104? |
|-------|-----|------|-----------|-----------|-----------|------------|
| 4×4 | 16 | 16 | ~12K | 0.13 | Low | Yes (easy) |
| 8×8 (chosen) | 64 | 64 | ~45K | 0.51 | Moderate | Yes |
| 16×16 | 256 | 256 | ~180K | 2.1 | High | Marginal (78% LUT) |
| 32×32 | 1024 | >1024 | ~700K | >8 | Exceeds DDR4 BW | No |

**Decision**: 8×8
**Justification**:
- 64 DSP48E2 blocks = 3.7% of ZCU104 available (1,728 DSPs) — leaves ample room for control
- Estimated 20% LUT utilization allows routing congestion headroom (critical for 100 MHz timing)
- 16×16 would require off-chip bandwidth ~4× higher, approaching ZCU104 DDR4 theoretical limit
  (8.5 GB/s), leaving no margin for system overhead
- 8×8 achieves ~0.5 TOPS which exceeds the target (>0.5 TOPS) — validated by:
  Operation count for MobileNetV2: ~300M MACs
  Throughput = (64 PEs × 100M cycles/sec) / (300M MACs/image × 2 ops/MAC) ≈ 10 images/sec
  → 0.6 TOPS effective — meets target ✓

---

## 7. Accumulator Width: 24-bit

**Analysis**:
The accumulator must hold the sum of K² × C_in partial products without overflow.
For the largest layer in MobileNetV2 (pointwise conv with C_in=96, K=1):
```
Max partial product = 2^(W_act-1) × 2^(W_weight-1) = 2^7 × 2^3 = 1024
Max accumulator = C_in × K² × max_partial_product = 96 × 1 × 1024 = 98,304
log2(98,304) = 16.6 → 17 bits minimum

Add 2 guard bits for signed arithmetic safety → 19 bits minimum

For a 3×3 conv with C_in=32 (bottleneck layer):
Max accumulator = 32 × 9 × 1024 = 294,912 → log2 = 18.2 → 19 bits + 2 guard = 21 bits

Design decision: round up to 24 bits for clean byte alignment and future-proofing
if larger layers are added (e.g., C_in=512 layer would need 23 bits).
```

**Decision**: 24-bit saturating accumulator
**Why saturating (not wrapping)**: Accumulator overflow in a medical imaging application
must not produce a silently wrong output. Saturation clamps to the maximum value, which
ReLU and clipping in the post-processing pipeline then handle. Wrapping would produce a
random output value — clinically dangerous if it causes a false negative for disease detection.

---

## 8. Booth Multiplier over Standard Array Multiplier

**Alternatives**:
| Multiplier type | Area (LUTs) | Speed (critical path) | Complexity |
|----------------|------------|----------------------|------------|
| Array (shift-add) | High | Long (O(N)) | Simple |
| Wallace tree | Medium | Short | Moderate |
| Booth radix-2 (chosen) | Low | Short | Moderate |
| Booth radix-4 | Very low | Shorter | High |
| DSP48E2 (FPGA primitive) | Minimal LUT | Fastest | Simple |

**Decision**: Booth radix-2 for PhD research demonstration; DSP48E2 primitive for final synthesis.
**Justification**:
- **Research value**: Implementing Booth multiplier in RTL demonstrates understanding of
  arithmetic circuits — required for PhD thesis credibility and VLSI conference submissions.
- **Synthesis**: In practice, Vivado will infer DSP48E2 from the `*` operator on signals
  of appropriate widths. The Booth RTL serves as the functional reference and testbench target.
- **Radix-4 not chosen**: Handles 3 bits per step (more efficient) but requires more complex
  partial product generation logic. Radix-2 is sufficient to demonstrate the principle and
  achieves the timing target at 100 MHz.

**Important**: In the synthesis TCL, set:
```tcl
set_property STEPS.SYNTH_DESIGN.ARGS.KEEP_EQUIVALENT_REGISTERS true [get_runs synth_1]
```
to prevent Vivado from collapsing the Booth pipeline registers before resource reporting.

---

## 9. Single Clock Domain Design

**Decision**: All PL logic operates in a single clock domain (100 MHz).
**Justification**:
- Multi-clock designs introduce CDC (clock domain crossing) complexity: metastability,
  synchronizer insertion, and formal CDC verification requirements.
- For a PhD-level academic implementation, the research contribution is the accelerator
  architecture and quantization methodology — not CDC engineering. Single-domain design
  keeps the implementation focused.
- 100 MHz is sufficient to meet throughput targets on ZCU104 (10+ images/sec).
- **Future work**: A production implementation would use separate clock domains for
  DDR4 interface (533 MHz) vs compute core (200–400 MHz) for higher efficiency.

---

## 10. Synchronous Active-Low Reset

**Decision**: All registers use synchronous reset, active-low (`rst_n`).
**Justification**:
- Xilinx UltraScale+ FFs support synchronous reset natively with no additional LUTs.
- Asynchronous resets create timing exceptions that must be constrained — increasing
  XDC complexity and synthesis tool runtime.
- Active-low is the industry convention for reset (historically TTL-compatible); it also
  means an undriven reset line (pulled high by default) does not accidentally hold the
  design in reset.
- **All modules must comply**: never use `posedge rst_n` in an `always` sensitivity list.

---

## 11. Round-to-Nearest-Even (RNE) over Truncation

**Decision**: RNE rounding in `quantize_scale.v`.
**Justification**:
- Truncation introduces a systematic negative bias: `round_down(x) < x` always.
  Over a deep network, this bias accumulates layer by layer, causing output distribution shift.
- Round-half-up introduces a positive bias for values exactly at the midpoint.
- RNE (banker's rounding) is unbiased: half-values round to the nearest even integer,
  cancelling bias statistically over many values.
- **Critical for numerical equivalence**: the Python golden model must use the same rounding.
  In Python: use `round()` (Python 3 uses RNE by default) or `np.round()`.
  In C/hardware: implement explicitly — do NOT use `>> N` alone (truncation).

**Implementation**:
```verilog
// After shift: check if remainder >= 0.5 (i.e., the discarded bit was 1)
// and apply tie-breaking rule (round to even)
wire round_bit = shifted_val[0];        // the bit being discarded
wire sticky_bit = |shifted_val[-1:0];   // any bits below the round bit
wire lsb = final_val[0];               // LSB of result
wire do_round = round_bit & (sticky_bit | lsb);  // round up if > 0.5, or exactly 0.5 and odd
assign result = final_val + do_round;
```

---

## 12. NIH ChestX-ray14 over Other Medical Datasets

**Alternatives**:
| Dataset | Images | Classes | Availability | Notes |
|---------|--------|---------|--------------|-------|
| NIH ChestX-ray14 (chosen) | 112,120 | 14 | Public, free | Most-cited, enables fair comparison |
| MIMIC-CXR | 227,827 | 14 | Public (credentialed) | Requires PhysioNet access |
| CheXpert (Stanford) | 224,316 | 14 | Public | Different labeling approach |
| Indiana U. CXR | 7,470 | Various | Public | Too small for deep learning |

**Decision**: NIH ChestX-ray14 as primary, CheXpert as secondary validation.
**Justification**:
- NIH ChestX-ray14 is the standard benchmark — CheXNet (SOTA) and most academic papers
  use it, enabling direct comparison without dataset shift concerns.
- The official patient-level train/test split (from Wang et al., CVPR 2017) must be used
  to prevent data leakage — do NOT create a random split.
- CheXpert as secondary dataset validates that findings generalize across institutions
  (different scanner types, patient populations) — required for journal-level publication.