# CNN Accelerator Implementation Plan
## PhD-Level Hardware Design Plan: Quantized CNN Accelerator for Medical Imaging on FPGA

---

## Research Identity

**Title**: A Quantization-Aware Fixed-Point CNN Accelerator for Real-Time Chest X-Ray Disease
Classification on FPGA

**Research Gap**: Existing CNN accelerators (Eyeriss, ShiDianNao, NVDLA) target general-purpose
vision workloads. Medical imaging has distinct requirements — high sensitivity/specificity tradeoffs,
class imbalance (~50:1 in NIH ChestX-ray14), and strict latency/power budgets for portable
point-of-care devices — that are not addressed by existing architectures.

**Primary Contributions**:
1. Mixed-precision quantization scheme (4-bit weights / 8-bit activations) tuned for medical
   image sensitivity preservation, with formal accuracy-loss bounds.
2. Output-stationary dataflow with a tiled 8×8 PE array optimized for small-batch medical
   inference (batch size = 1), minimizing off-chip memory traffic.
3. Hardware-software co-design framework with bit-accurate Python golden model enabling
   numerical equivalence verification between floating-point training and fixed-point hardware.
4. End-to-end deployment on Xilinx Zynq UltraScale+ ZCU104 with measured TOPS/W and
   area efficiency superior to state-of-the-art medical FPGA accelerators.

---

## Phase Overview

```
Phase 1: Literature Review & Gap Analysis       [2–3 months]
Phase 2: Quantization-Aware Model Development   [2–3 months]
Phase 3: Architecture Specification             [1–2 months]
Phase 4: RTL Implementation (Verilog)           [4–6 months]
Phase 5: Simulation & Formal Verification       [2–3 months]
Phase 6: FPGA Synthesis, PnR & Validation       [3–4 months]
Phase 7: Benchmarking & Publication             [3–4 months]
                                    TOTAL:  ~17–25 months
```

---

## Phase 1: Literature Review & Gap Analysis
**Duration**: 2–3 months
**Exit Criteria**: Documented novelty matrix comparing this work against ≥10 prior works.

### 1.1 Accelerator Architecture Survey
| Paper | Dataflow | Precision | Target | TOPS/W | Notes |
|-------|----------|-----------|--------|--------|-------|
| Eyeriss (JSSC 2017) | Row-stationary | 16-bit | ASIC | 0.166 | Baseline comparison |
| ShiDianNao (ISCA 2015) | Output-stationary | 16-bit | ASIC | – | Nearest-neighbour reuse |
| NVDLA | Weight-stationary | INT8 | ASIC | – | Industry reference |
| Angel-Eye (TCAD 2019) | Weight-stationary | 8-bit | FPGA | 3.0 | FPGA SOTA |
| (this work) | Output-stationary | W4A8 | FPGA | target: >4.0 | Medical-specific |

**Key papers to read**:
- Chen et al., "Eyeriss: An Energy-Efficient Reconfigurable Accelerator for Deep CNNs," JSSC 2017
- Du et al., "ShiDianNao: Shifting Vision Processing Closer to the Sensor," ISCA 2015
- Guo et al., "Angel-Eye: A Complete Design Flow for Mapping CNN onto Embedded FPGA," TCAD 2018
- Jacob et al., "Quantization and Training of Neural Networks for Efficient Integer-Arithmetic-Only Inference," CVPR 2018
- Nagel et al., "A White Paper on Neural Network Quantization," arXiv 2021
- Rajpurkar et al., "CheXNet: Radiologist-Level Pneumonia Detection on Chest X-Rays," arXiv 2017

### 1.2 Medical Dataset Analysis
- **Primary Dataset**: NIH ChestX-ray14 (112,120 images, 14 pathology classes)
- **Secondary Dataset**: MIMIC-CXR (227,827 images, multi-label)
- **Key Challenge**: Class imbalance — document per-class positive rates
- **Preprocessing**: Histogram equalization, normalization to [0,1], resize to 224×224
- **Metrics**: AUC-ROC per class (primary), sensitivity @ 90% specificity (clinical threshold)

### 1.3 Deliverables
- [ ] Novelty matrix (this work vs. ≥10 prior works across 8 dimensions)
- [ ] Dataset characterization report (class distribution, image statistics)
- [ ] Research gap statement (1–2 pages, journal quality)

---

## Phase 2: Quantization-Aware Model Development
**Duration**: 2–3 months
**Exit Criteria**: Quantized model achieving AUC-ROC ≥0.80 on NIH ChestX-ray14 with <2%
accuracy drop vs. FP32 baseline. Bit-accurate Python golden model passing numerical equivalence
tests against RTL simulation outputs.

### 2.1 Baseline Floating-Point Model
- **Architecture**: MobileNetV2 (pretrained ImageNet) fine-tuned on NIH ChestX-ray14
  - Justified over SqueezeNet: better accuracy/compute tradeoff at equivalent parameter count
  - Justified over ResNet-50: lower FPGA resource demand, suitable for portable device
- **Training Protocol**:
  - Optimizer: Adam, lr=1e-4, cosine annealing schedule
  - Loss: Weighted binary cross-entropy (weight = inverse class frequency)
  - Augmentation: random horizontal flip, ±10° rotation, ±10% brightness
  - Batch size: 32, epochs: 50, early stopping patience: 10
  - Hardware: GPU (document: model/version, CUDA version)
- **Target Baseline**: AUC-ROC ≥ 0.83 per class (matching CheXNet reported performance)

### 2.2 Quantization Strategy
**Scheme**: Mixed-precision W4A8 (4-bit weights, 8-bit activations)
- Rationale: Weights dominate memory; activations require higher precision for gradient magnitude
  preservation in medical sensitivity-critical features.
- **Method**: Quantization-Aware Training (QAT) using PyTorch `torch.quantization`
  - Straight-Through Estimator (STE) for gradient of quantize op
  - Per-channel weight quantization (asymmetric, affine)
  - Per-tensor activation quantization (symmetric)
  - Calibration: 1000-sample representative subset of training set

**Bit-Width Analysis** (must document for each layer):
```
For each layer l:
  - Weight range:    [w_min_l, w_max_l]  → scale_w_l, zero_w_l
  - Activation range: [a_min_l, a_max_l]  → scale_a_l, zero_a_l
  - Accumulator width: ceil(log2(K*K*C_in)) + W_weight + W_act bits
    where K=kernel size, C_in=input channels
    Example: 3×3 conv, 64 channels → ceil(log2(576)) + 4 + 8 = 10 + 12 = 22-bit accumulator
  - Guard bits: 2 (prevent overflow in accumulation)
  - Final accumulator: 24-bit, truncated to 8-bit after scale/shift
```

**Overflow / Saturation Policy**:
- Saturating arithmetic (clamp, not wrap): critical for medical imaging
- Document: maximum theoretical accumulator value per layer, verify ≤ accumulator width

### 2.3 Fixed-Point Golden Model (Python)
A **bit-accurate** Python model that mirrors the exact integer arithmetic of the RTL:
- Implements integer-only MAC: `acc += int(weight_q) * int(activation_q)`
- Applies same rounding mode as hardware (round-to-nearest-even)
- Exports per-layer input/output tensors as test vectors (`.hex` files) for RTL testbenches
- Verification: output of golden model ≡ output of RTL simulation (bit-exact match)

### 2.4 Deliverables
- [ ] `python/baseline_fp32.py` — FP32 MobileNetV2 training on NIH ChestX-ray14
- [ ] `python/quantize_qat.py` — QAT training script (W4A8)
- [ ] `python/golden_model.py` — Bit-accurate fixed-point inference
- [ ] `python/export_test_vectors.py` — Export `.hex` test vectors per layer
- [ ] Accuracy table: FP32 baseline vs. PTQ vs. QAT (AUC-ROC per class)

---

## Phase 3: Architecture Specification
**Duration**: 1–2 months
**Exit Criteria**: Signed-off architecture document with block diagrams, resource estimates,
and timing budget. No ambiguity in any interface signal.

### 3.1 Dataflow Selection: Output-Stationary (OS)
**Justification**: For batch-size-1 medical inference:
- OS minimizes partial sum movement — accumulators stay in PE registers
- Weight reuse across the spatial dimension within a single image
- Lower off-chip bandwidth vs. weight-stationary for deep networks with large feature maps

**Comparison** (document formally):
| Dataflow | Off-chip reads/op | On-chip storage | Best for |
|----------|-------------------|-----------------|----------|
| Weight-stationary | High (activations) | Low | Large batch |
| Input-stationary | Medium | Medium | RNNs |
| Output-stationary | Low (partial sums stay) | Medium | Single inference |
| Row-stationary | Lowest (Eyeriss) | Highest | ASIC |

### 3.2 Processing Element (PE) Array
```
Array size: 8×8 = 64 PEs
Each PE contains:
  - 1× Booth's radix-2 multiplier: 8-bit × 4-bit → 12-bit
  - 1× 24-bit saturating accumulator
  - Local register file: 4×8-bit (activation buffer), 8×4-bit (weight buffer)

PE Datapath (per cycle):
  acc[24] += sign_extend(weight[4]) × zero_extend(activation[8])
  → partial product: 12-bit
  → accumulated into 24-bit register (no overflow given guard bits analysis in §2.2)
```

### 3.3 Memory Hierarchy
```
Level 0 — PE Register File (per PE):
  - 4 activation registers × 8-bit  =  32 bits
  - 8 weight registers   × 4-bit    =  32 bits
  - 1 accumulator        × 24-bit   =  24 bits

Level 1 — On-Chip SRAM (shared, dual-port):
  - Weight Buffer:      256 KB  (holds one conv layer's filters)
  - Activation Buffer:  128 KB  (input feature map tile)
  - Output Buffer:       64 KB  (output feature map tile)
  Total on-chip SRAM:   448 KB  → verify fits UltraScale+ BRAM budget (ZCU104: 11 Mb)

Level 2 — Off-Chip DDR4 (via AXI4 Master):
  - Full model weights: ~13 MB (MobileNetV2 @ W4)
  - Full activation maps: ~25 MB (8-bit, 224×224×64)
  - Bandwidth requirement: document peak GB/s requirement vs. ZCU104 DDR4 bandwidth (2× 32-bit @ 1066 MHz = ~8.5 GB/s)
```

### 3.4 Interface Design
```
External interfaces:
  AXI4-Lite  (control plane): register map for start/stop, layer config, interrupt
  AXI4       (data plane):    DMA bursts for weight/activation transfer from DDR4
  AXI4-Stream (pixel input):  streaming pixel data from image sensor / PS

Internal interfaces (all synchronous, posedge clk, active-low rst_n):
  PE ↔ Weight SRAM:      4-bit wide, 64-wide (one weight per PE per cycle)
  PE ↔ Activation SRAM:  8-bit wide, 8-wide  (one activation row per cycle)
  PE ↔ Output SRAM:      24-bit wide, 64-wide (drain accumulators post-tile)
```

### 3.5 Pipeline Stages (5-stage)
```
Stage 1 — FETCH_W:    Load weights from Weight SRAM → PE register files
Stage 2 — FETCH_A:    Load activations from Activation SRAM → PE register files
Stage 3 — COMPUTE:    Booth multiply (8×4→12-bit), one cycle latency
Stage 4 — ACCUMULATE: Add to 24-bit accumulator, saturating
Stage 5 — WRITEBACK:  After tile complete, scale→shift→clip to 8-bit, write Output SRAM
```

### 3.6 Resource Estimation (pre-synthesis)
| Resource | Estimated | ZCU104 Available | Utilization |
|----------|-----------|-----------------|-------------|
| LUT | ~45,000 | 230,400 | ~20% |
| FF | ~30,000 | 460,800 | ~7% |
| BRAM (36K) | ~100 | 312 | ~32% |
| DSP48E2 | 64 (one per PE) | 1,728 | ~4% |
| IO | ~50 | 328 | ~15% |

### 3.7 Deliverables
- [ ] `docs/architecture.md` — full block diagram descriptions, interface tables
- [ ] `docs/design_decisions.md` — dataflow choice, precision choice, array sizing
- [ ] `synthesis/constraints/cnn.xdc` — updated with all clock domains, IO standards

---

## Phase 4: RTL Implementation (Verilog)
**Duration**: 4–6 months
**Exit Criteria**: All modules passing unit testbenches with ≥95% statement coverage
and ≥90% branch coverage. Top-level simulation passing golden model comparison.

### 4.1 Module Hierarchy
```
top.v  (AXI4 interfaces, PS-PL bridge)
└── cnn_accelerator.v  (top-level accelerator, layer scheduler)
    ├── layer_controller.v     (FSM: controls tile iteration, layer sequencing)
    ├── dma_engine.v           (AXI4 master: weight/activation DMA bursts)
    ├── pe_array.v             (8×8 array instantiation + interconnect)
    │   └── pe.v [×64]         (single PE: multiplier + accumulator + register file)
    │       └── booth_mult.v   (Booth radix-2: 8×4→12-bit, pipelined 2 stages)
    ├── weight_sram.v          (256 KB dual-port BRAM wrapper)
    ├── activation_sram.v      (128 KB dual-port BRAM wrapper)
    ├── output_sram.v          (64 KB dual-port BRAM wrapper)
    ├── quantize_scale.v       (post-accumulation: scale, shift, clip to 8-bit)
    ├── relu.v                 (8-bit saturating ReLU)
    ├── max_pool.v             (2×2 max pooling, streaming)
    └── axi4_lite_slave.v      (control register file)
```

### 4.2 Critical Module Specifications

**booth_mult.v** (replace current stub):
- Interface: `input [7:0] activation, input [3:0] weight, output [11:0] product`
- Signed/unsigned: weight is signed 4-bit (two's complement), activation is unsigned 8-bit
- Latency: 2 clock cycles (pipelined) — document pipeline stages explicitly
- Verification: exhaustive simulation of all 2^12 input combinations

**pe.v**:
- Accumulator: 24-bit, saturating at {24{1'b1}} (max positive)
- Clear signal: `acc_clear` — driven by layer_controller at tile boundary
- Output: `acc_out [23:0]` — valid when `acc_valid` asserted

**quantize_scale.v**:
- Implements: `output = clip(round((acc × M) >> N), 0, 255)`
  where M (multiplier) and N (shift) are layer-specific parameters loaded from register file
- M: 16-bit unsigned, N: 4-bit unsigned (shift amount 0–15)
- Rounding: round-to-nearest-even (must match Python golden model exactly)

**layer_controller.v** (FSM):
```
States: IDLE → LOAD_CONFIG → FETCH_WEIGHTS → COMPUTE_TILE →
        DRAIN_OUTPUT → NEXT_TILE → NEXT_LAYER → DONE
Registers: tile_row, tile_col, layer_id, in_channel_idx, out_channel_idx
Outputs: SRAM read/write enables, PE array control signals, DMA requests
```

### 4.3 Coding Standards
- All modules: synchronous reset (active-low `rst_n`), single clock domain (`clk`)
- No latches: use `always @(posedge clk)` for sequential, `always @(*)` for combinational
- Parameters over `define`: use `parameter`/`localparam` for configurability
- Simulation-only blocks: wrap in `` `ifndef SYNTHESIS `` guards
- No `integer` loop variables in synthesizable code: use `genvar` for generate loops
- Signal naming: `_i` suffix for inputs to module, `_o` for outputs, `_r` for registers, `_w` for wires

### 4.4 Deliverables
- [ ] All modules in `hardware/` with complete implementations (no stubs)
- [ ] `hardware/pe.v` — single PE with Booth multiplier and accumulator
- [ ] `hardware/pe_array.v` — 8×8 generate loop instantiation
- [ ] `hardware/layer_controller.v` — complete FSM
- [ ] `hardware/quantize_scale.v` — post-accumulation scaling
- [ ] `hardware/axi4_lite_slave.v` — control interface

---

## Phase 5: Simulation & Formal Verification
**Duration**: 2–3 months
**Exit Criteria**: All tests pass. Golden model numerical equivalence verified for
≥100 test images from NIH ChestX-ray14. Formal property checks pass on FSM.

### 5.1 Unit Testbench Requirements (per module)
Each testbench must include:
1. **Directed tests**: hand-crafted corner cases (zero input, max input, saturation)
2. **Random tests**: constrained-random inputs, ≥10,000 vectors
3. **Golden comparison**: Python-generated expected outputs checked cycle-by-cycle
4. **Coverage report**: statement ≥95%, branch ≥90%, toggle ≥85%

**booth_mult_tb.v** — Critical:
- Exhaustive: all 2^12 (4096) combinations of 8-bit × 4-bit
- Compare against Python: `int(np.int8(w)) * int(np.uint8(a))`
- Check pipeline timing: output valid exactly 2 cycles after input

**pe_tb.v**:
- Test accumulation overflow → verify saturation (not wrap)
- Test acc_clear timing (must clear on cycle boundary, not mid-accumulation)

**layer_controller_tb.v** (FSM):
- Verify all state transitions with assertion checks (`assert` statements)
- Test layer sequencing: 5 consecutive layers with correct index increments
- Deadlock detection: assert no state persists >1000 cycles without transition

**top_level_tb.v**:
- Feed complete 28×28 grayscale test image via AXI4-Stream
- Compare final classification output vs. Python golden model
- Measure latency (clock cycles) from first pixel to valid output

### 5.2 Golden Model Co-Simulation
```
Flow:
  Python golden_model.py → per-layer .hex test vectors
       ↓
  Verilog $readmemh() loads test vectors
       ↓
  Simulation runs layer-by-layer
       ↓
  Verilog $fwrite() dumps output .hex
       ↓
  Python compare_outputs.py → assert bit-exact match
       ↓
  PASS/FAIL report with mismatch locations
```

### 5.3 Formal Verification (Bounded Model Checking)
Using SymbiYosys (open-source) or Cadence JasperGold:
- **Property 1**: Accumulator never exceeds 24-bit signed maximum
- **Property 2**: FSM is deadlock-free (no unreachable states)
- **Property 3**: AXI4-Lite read/write handshake protocol compliance
- **Property 4**: Output valid signal de-asserts within 1 cycle of rst_n assertion

### 5.4 Deliverables
- [ ] `testbench/booth_mult_tb.v` — exhaustive multiplier verification
- [ ] `testbench/pe_tb.v` — PE accumulation and saturation tests
- [ ] `testbench/layer_controller_tb.v` — FSM verification
- [ ] `testbench/top_level_tb.v` — end-to-end co-simulation
- [ ] `python/compare_outputs.py` — bit-exact comparison script
- [ ] Coverage report (Icarus + lcov or Verilator coverage)

---

## Phase 6: FPGA Synthesis, Place-and-Route & Hardware Validation
**Duration**: 3–4 months
**Exit Criteria**: Bitstream running at ≥100 MHz, hardware output matches simulation
output for all test images. Power measured with Xilinx Power Analyzer.

### 6.1 Synthesis Strategy
- **Tool**: Xilinx Vivado 2023.1
- **Target**: Zynq UltraScale+ ZCU104 (xczu7ev-ffvc1156-2-e)
- **Clock**: 100 MHz primary (10 ns period), with 5 ns uncertainty margin in XDC

**Synthesis settings**:
```tcl
set_property STEPS.SYNTH_DESIGN.ARGS.DIRECTIVE PerformanceOptimized [get_runs synth_1]
set_property STEPS.SYNTH_DESIGN.ARGS.RETIMING true [get_runs synth_1]
set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE Explore [get_runs impl_1]
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraNetDelay_high [get_runs impl_1]
set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE AggressiveExplore [get_runs impl_1]
```

### 6.2 Timing Closure Plan
Timing closure is the highest-risk activity. If timing fails:
1. **Step 1**: Check critical path — identify offending module (likely pe_array or booth_mult)
2. **Step 2**: Add pipeline register stage in critical path (accept +1 cycle latency)
3. **Step 3**: Apply `KEEP_HIERARCHY` and manual floorplanning (Pblock) on PE array
4. **Step 4**: Reduce clock to 85 MHz if step 1–3 insufficient (document as design point)
5. **Step 5**: Consider retiming with `set_multicycle_path` for non-critical paths

### 6.3 Power Analysis
- Tool: Xilinx Power Estimator (XPE) + post-implementation power report
- Measure: static power, dynamic power (at target workload: continuous inference)
- Target: total board power ≤ 5W (portable device constraint)
- Report: power breakdown by module (document BRAM, DSP, LUT, IO contributions)

### 6.4 Hardware Validation
```
Validation flow:
  Load bitstream via JTAG (Xilinx Platform Cable USB II)
       ↓
  PS (ARM Cortex-A53) sends test images via AXI4-Stream DMA
       ↓
  PL (accelerator) computes inference
       ↓
  PS reads output classification vector
       ↓
  Compare vs. Python golden model output (via serial / UART log)
       ↓
  Measure: latency (oscilloscope / ILA), throughput (images/sec), power (power rail monitor)
```

**Xilinx ILA (Integrated Logic Analyzer)** probes:
- `layer_controller` FSM state register
- AXI4 handshake signals (VALID/READY)
- PE array output valid + first PE accumulator value

### 6.5 Deliverables
- [ ] `synthesis/scripts/synthesize_top.tcl` — complete synthesis + implementation script
- [ ] `synthesis/constraints/cnn.xdc` — complete timing + IO constraints
- [ ] Timing report (WNS, TNS — must be ≥0 ns)
- [ ] Power report (static + dynamic breakdown)
- [ ] Hardware validation log (per-image comparison table)

---

## Phase 7: Benchmarking & Publication
**Duration**: 3–4 months
**Exit Criteria**: Submitted to ≥1 target venue. All results reproducible from scripts.

### 7.1 Benchmarking Metrics (must report all)
| Metric | Formula | Target | Comparison Baseline |
|--------|---------|--------|---------------------|
| Inference latency | clock cycles × T_clk | <50 ms/image | Angel-Eye: ~30 ms |
| Throughput | images/sec | >20 fps | — |
| TOPS | (2×K²×C_in×C_out×H×W) / (latency × 10^12) | >0.5 TOPS | — |
| Energy/inference | power × latency | <0.1 J | — |
| TOPS/W | TOPS / total_power | >4.0 | Angel-Eye: 3.0 |
| Area (LUT-eq) | LUT + 2×FF + 64×BRAM | document | — |
| Accuracy (AUC-ROC) | per-class + mean | ≥0.80 | CheXNet: 0.84 |
| Accuracy drop vs FP32 | FP32_AUC - Q_AUC | <0.02 | — |

### 7.2 Ablation Studies (required for PhD thesis/journal)
1. **Precision ablation**: W8A8 vs W4A8 vs W4A4 — accuracy vs. hardware cost tradeoff
2. **Array size ablation**: 4×4 vs 8×8 vs 16×16 PE arrays — throughput vs. area
3. **Dataflow ablation**: OS vs WS — off-chip bandwidth measurement
4. **Quantization method**: PTQ vs QAT — accuracy gap on NIH ChestX-ray14

### 7.3 Statistical Reporting
- All AUC-ROC values: 95% confidence interval (bootstrap, n=1000)
- Latency: mean ± std over 100 test images
- p-values for accuracy comparisons (Wilcoxon signed-rank test vs. FP32 baseline)

### 7.4 Target Venues (in priority order)
| Venue | Type | Deadline cycle | Acceptance rate |
|-------|------|----------------|-----------------|
| IEEE Trans. Biomedical Circuits & Systems | Journal | Rolling | ~25% |
| IEEE Trans. Medical Imaging | Journal | Rolling | ~30% |
| IEEE ISCAS | Conference | ~Nov each year | ~40% |
| ACM/IEEE DAC | Conference | ~Nov each year | ~23% |
| IEEE BioCAS | Conference | ~May each year | ~35% |

### 7.5 Paper Structure
1. **Abstract** (250 words): problem, method, key results (TOPS/W, AUC-ROC)
2. **Introduction**: medical imaging need, FPGA advantage, contributions (bulleted)
3. **Related Work**: accelerator survey table (§1.1), quantization survey, medical CNN survey
4. **Quantization Methodology**: W4A8 scheme, QAT protocol, bit-width analysis, accuracy results
5. **Hardware Architecture**: dataflow, PE array, memory hierarchy, pipeline stages
6. **Implementation**: RTL details, synthesis results, resource utilization table
7. **Experimental Results**: all benchmarking metrics (§7.1), ablation studies (§7.2)
8. **Discussion**: accuracy-efficiency tradeoff, clinical deployment considerations, limitations
9. **Conclusion**: summary of contributions, future work (INT4 on newer FPGA families)

### 7.6 Deliverables
- [ ] Benchmarking script: `python/benchmark.py` (automated end-to-end measurement)
- [ ] Results table: `docs/results.md` (all metrics, reproducible)
- [ ] Paper draft (LaTeX, IEEE format)
- [ ] Open-source release: GitHub with RTL, Python scripts, test vectors, and synthesis scripts

---

## Risk Register

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|-----------|
| Timing closure fails at 100 MHz | Medium | High | Reduce to 85 MHz; add pipeline stages proactively |
| QAT accuracy drop >2% | Medium | High | Fall back to W8A8; adjust per-layer sensitivity |
| NIH ChestX-ray14 licensing delays | Low | Medium | Use public CheXpert (Stanford) as fallback dataset |
| BRAM budget exceeded | Low | Medium | Reduce Weight Buffer to 128 KB; add double-buffering |
| Off-chip bandwidth bottleneck | Medium | Medium | Increase tile size; profile with ILA |
| PE array critical path too long | Medium | High | Reduce to 4×4; document as design point |

---

## Key Design Invariants (never violate)
1. Accumulator arithmetic is always **saturating** — never wrapping. Medical correctness requires this.
2. Rounding mode is always **round-to-nearest-even** — must match Python golden model exactly.
3. AXI4 protocol compliance is **formally verified** before hardware testing.
4. Every module has a **synchronous active-low reset** — no asynchronous resets in the accelerator.
5. Golden model comparison is **bit-exact** — approximate matches are not accepted.