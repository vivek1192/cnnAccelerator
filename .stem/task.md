# Task Checklist: Quantized CNN Accelerator for Medical Imaging on FPGA
## PhD-Level Implementation Checklist

---

## Phase 1: Literature Review & Gap Analysis

### 1.1 Accelerator Survey
- [ ] Read and annotate Eyeriss (Chen et al., JSSC 2017) — extract dataflow, area, TOPS/W
- [ ] Read and annotate ShiDianNao (Du et al., ISCA 2015) — output-stationary reference
- [ ] Read and annotate Angel-Eye (Guo et al., TCAD 2018) — FPGA SOTA baseline
- [ ] Read NVDLA architecture whitepaper — weight-stationary reference
- [ ] Read Jacob et al. CVPR 2018 — QAT methodology (implement §3 fixed-point scheme)
- [ ] Read Nagel et al. 2021 white paper — per-channel vs per-tensor quantization analysis
- [ ] Read CheXNet (Rajpurkar et al.) — target accuracy baseline for NIH ChestX-ray14

### 1.2 Novelty Matrix
- [ ] Build comparison table (≥10 papers × 8 dimensions: dataflow, precision, target, TOPS/W,
      application domain, memory hierarchy, area, power)
- [ ] Identify and document ≥3 clear research gaps this work addresses
- [ ] Write 1-page research gap statement (journal quality)

### 1.3 Dataset Characterization
- [ ] Download NIH ChestX-ray14 dataset (112,120 images) and verify integrity
- [ ] Compute per-class positive rate → document class imbalance ratios
- [ ] Compute image statistics: mean, std per channel for normalization constants
- [ ] Define train/val/test split (follow official NIH split — do NOT split randomly)
- [ ] Confirm: test set has no patient overlap with training set (patient-level split)

---

## Phase 2: Quantization-Aware Model Development

### 2.1 Environment Setup
- [ ] Create `requirements.txt`: torch, torchvision, numpy, pillow, pandas, scikit-learn
- [ ] Document exact versions: Python, PyTorch, CUDA, GPU model
- [ ] Verify NIH ChestX-ray14 data pipeline: image loading, augmentation, DataLoader

### 2.2 Baseline FP32 Model
- [ ] Implement `python/baseline_fp32.py`:
  - [ ] MobileNetV2 with ImageNet pretrained weights
  - [ ] Replace final classifier: `Linear(1280, 14)` with sigmoid output
  - [ ] Weighted binary cross-entropy loss (weight = inverse class frequency)
  - [ ] Adam optimizer, lr=1e-4, cosine annealing (T_max=50)
  - [ ] Early stopping: patience=10 on validation AUC-ROC (mean)
  - [ ] Save best checkpoint: `checkpoints/mobilenetv2_fp32_best.pth`
- [ ] Verify baseline: mean AUC-ROC ≥ 0.80 on NIH test set
- [ ] Log and report per-class AUC-ROC (14 classes) with 95% CI (bootstrap n=1000)

### 2.3 Bit-Width Analysis (document before coding hardware)
- [ ] For each layer in MobileNetV2, measure:
  - [ ] Weight value range [w_min, w_max] after training
  - [ ] Activation value range [a_min, a_max] on calibration set (1000 images)
  - [ ] Required accumulator width: `ceil(log2(K²×C_in)) + W_weight + W_act`
- [ ] Confirm: no layer requires accumulator > 24 bits under W4A8 scheme
- [ ] Document: layers most sensitive to quantization (use per-layer AUC-ROC drop as metric)

### 2.4 Quantization-Aware Training
- [ ] Implement `python/quantize_qat.py`:
  - [ ] Load FP32 checkpoint, apply `torch.quantization.prepare_qat()`
  - [ ] Per-channel weight quantization (asymmetric, 4-bit)
  - [ ] Per-tensor activation quantization (symmetric, 8-bit)
  - [ ] STE gradient through quantize op (verify: PyTorch default behavior)
  - [ ] Fine-tune: lr=1e-5, 20 epochs max, early stopping patience=5
  - [ ] Save: `checkpoints/mobilenetv2_w4a8_best.pth`
- [ ] Report accuracy table: FP32 vs PTQ vs QAT (mean AUC-ROC ± CI)
- [ ] Verify: QAT accuracy drop vs FP32 < 0.02 AUC-ROC (if not, tune per-layer precision)

### 2.5 Bit-Accurate Golden Model
- [ ] Implement `python/golden_model.py`:
  - [ ] Integer-only MAC: `acc += int(weight_q) * int(activation_q)` (no floating point)
  - [ ] Accumulator: Python `int` (unbounded) clamped to 24-bit signed after each layer
  - [ ] Scale/shift: `output = clip(round_half_to_even((acc × M) >> N), 0, 255)`
  - [ ] ReLU: `max(0, x)` on 8-bit unsigned
  - [ ] Max pool: sliding 2×2 window, stride 2
- [ ] Implement `python/export_test_vectors.py`:
  - [ ] Export per-layer inputs, weights, and expected outputs as `.hex` files
  - [ ] Format: one value per line, zero-padded to fixed width
  - [ ] Save to `testbench/test_vectors/layer_{n}_{input|weight|output}.hex`
- [ ] Implement `python/compare_outputs.py`:
  - [ ] Load RTL simulation output `.hex` vs golden model `.hex`
  - [ ] Assert bit-exact match — report first mismatch address and value if fail

---

## Phase 3: Architecture Specification

### 3.1 Dataflow Decision
- [ ] Formally compare OS vs WS vs IS dataflow for batch-size-1 MobileNetV2:
  - [ ] Compute off-chip memory reads per MAC operation for each dataflow
  - [ ] Select and document: output-stationary with justification
- [ ] Define tiling strategy: tile size T_h × T_w for each layer (fit in 128 KB activation buffer)

### 3.2 PE Array Design
- [ ] Specify PE array dimensions: 8×8 (document justification vs 4×4 and 16×16)
- [ ] Draw PE internal block diagram: multiplier → adder → accumulator register
- [ ] Define accumulator width: 24-bit (from §2.3 analysis)
- [ ] Define register file sizes per PE (activation buffer, weight buffer)
- [ ] Specify Booth multiplier: radix-2, 2-stage pipeline, 8-bit × 4-bit → 12-bit

### 3.3 Memory Hierarchy
- [ ] Calculate SRAM sizes:
  - [ ] Weight buffer: 256 KB (show calculation: max filter size × output channels)
  - [ ] Activation buffer: 128 KB (show calculation: tile size × input channels × 8-bit)
  - [ ] Output buffer: 64 KB (show calculation: tile size × output channels × 24-bit)
- [ ] Verify total SRAM (448 KB) fits ZCU104 BRAM budget (11 Mb available)
- [ ] Calculate peak off-chip bandwidth requirement, verify < ZCU104 DDR4 bandwidth

### 3.4 Interface Specification
- [ ] Define AXI4-Lite register map (base address, offset, field, R/W, description)
- [ ] Define AXI4 master burst parameters: burst length, size, type for DMA
- [ ] Define AXI4-Stream pixel input format: TDATA width, TLAST usage
- [ ] Document all internal interface signals: width, direction, timing relative to clock

### 3.5 Deliverables Check
- [ ] `docs/architecture.md` complete with all block diagrams and interface tables
- [ ] `docs/design_decisions.md` complete with all design choice justifications
- [ ] Pre-synthesis resource estimate table (LUT, FF, BRAM, DSP)

---

## Phase 4: RTL Implementation

### 4.1 Booth Multiplier (`hardware/booth_mult.v`)
- [ ] Interface: `input [7:0] activation_i, input signed [3:0] weight_i, output reg [11:0] product_o`
- [ ] 2-stage pipeline: Stage 1 partial products, Stage 2 final sum
- [ ] `valid_i` / `valid_o` handshake with 2-cycle delay
- [ ] Synthesizable: no `while` loops, no `integer` loop vars, use `genvar`
- [ ] No signed/unsigned mixing bugs: verify sign extension explicitly

### 4.2 Processing Element (`hardware/pe.v`)
- [ ] Instantiate `booth_mult.v`
- [ ] 24-bit saturating accumulator (saturate at `24'h7FFFFF`, not wrap)
- [ ] `acc_clear_i`: synchronous clear on posedge clk (not async)
- [ ] `acc_valid_o`: asserted when tile accumulation complete
- [ ] Local register file: 4×8-bit activation regs, 8×4-bit weight regs

### 4.3 PE Array (`hardware/pe_array.v`)
- [ ] Generate 8×8 PE instantiation with `genvar row, col`
- [ ] Weight broadcast: one weight to entire column (8 PEs share weight)
- [ ] Activation broadcast: one activation to entire row (8 PEs share activation)
- [ ] Output collection: 64 accumulator values, serialized to Output SRAM

### 4.4 SRAM Wrappers (`hardware/weight_sram.v`, `activation_sram.v`, `output_sram.v`)
- [ ] Use Xilinx BRAM primitive (`RAMB36E2`) or inferred dual-port RAM
- [ ] Port A: write from DMA engine
- [ ] Port B: read to PE array (weight/activation) or write from PE array (output)
- [ ] Output register: 1-cycle read latency (register output mode)

### 4.5 Quantize/Scale Unit (`hardware/quantize_scale.v`)
- [ ] Input: `acc_i [23:0]`, `scale_m_i [15:0]`, `shift_n_i [3:0]`
- [ ] Operation: `(acc × scale_m) >> shift_n` using 40-bit intermediate (24+16=40)
- [ ] Rounding: round-to-nearest-even on shifted result
- [ ] Clip: output `[7:0]` = clip(result, 0, 255)
- [ ] Verify rounding matches Python `round_half_to_even` exactly

### 4.6 Layer Controller FSM (`hardware/layer_controller.v`)
- [ ] States: IDLE, LOAD_CONFIG, FETCH_WEIGHTS, COMPUTE_TILE, DRAIN_OUTPUT,
              NEXT_TILE, NEXT_LAYER, DONE
- [ ] Tile iteration: nested loops (tile_row, tile_col, in_ch, out_ch) as registers
- [ ] Layer config registers: loaded from AXI4-Lite register file at LOAD_CONFIG
- [ ] Done interrupt: assert `done_irq_o` when all layers complete
- [ ] One-hot encoding for state register (safer for timing on FPGA)

### 4.7 DMA Engine (`hardware/dma_engine.v`)
- [ ] AXI4 master: read weights/activations from DDR4
- [ ] Burst: INCR type, 256-beat bursts (AWLEN=255), 64-bit wide
- [ ] State machine: IDLE, ISSUE_AR, WAIT_R, DONE
- [ ] Verify: AXI4 handshake (ARVALID/ARREADY, RVALID/RREADY) fully compliant

### 4.8 AXI4-Lite Slave (`hardware/axi4_lite_slave.v`)
- [ ] Register map implementation (≥8 registers: start, status, layer_count, base_addrs)
- [ ] Write path: AWVALID/AWREADY, WVALID/WREADY, BVALID/BREADY
- [ ] Read path: ARVALID/ARREADY, RVALID/RREADY
- [ ] Verify: no deadlock when VALID without READY

### 4.9 ReLU (`hardware/relu.v`) — fix existing
- [ ] Fix comparison bug: `if (in > 8'b0)` is comparing 16-bit to 8-bit — fix to `if (!in[15])`
  (MSB is sign bit; in[15]=0 means positive)
- [ ] Verify clamping: if `in[15:8] != 0` and positive, output = 255

### 4.10 Max Pool (`hardware/max_pool.v`) — fix existing
- [ ] Fix `integer i` — not synthesizable as written; replace with `reg [2:0] count_r`
- [ ] Remove blocking assignment inside `always @(posedge clk)` block
- [ ] Add proper 2D windowing: track row and column independently

### 4.11 Coding Standards Compliance (all files)
- [ ] No latches in synthesis (check for incomplete `if`/`case` without `default`)
- [ ] No `integer` variables in synthesizable always blocks
- [ ] All `case` statements have `default` clause
- [ ] All signals have reset values
- [ ] No mixed blocking/non-blocking assignments in same `always` block

---

## Phase 5: Simulation & Verification

### 5.1 Booth Multiplier Testbench (`testbench/booth_mult_tb.v`)
- [ ] Exhaustive: simulate all 4096 input combinations
- [ ] Verify output matches Python `int(np.int8(w)) * int(np.uint8(a))` for all inputs
- [ ] Verify 2-cycle pipeline latency: check `valid_o` timing
- [ ] Statement coverage ≥ 95%, branch coverage ≥ 90%

### 5.2 PE Testbench (`testbench/pe_tb.v`)
- [ ] Test: zero input (output should be 0)
- [ ] Test: max positive input → verify saturation (not overflow/wrap)
- [ ] Test: acc_clear timing — clear on boundary, not mid-accumulation
- [ ] Test: 100 random accumulation sequences with Python golden comparison

### 5.3 Quantize/Scale Testbench (`testbench/quantize_scale_tb.v`)
- [ ] Test: all rounding cases (exact half, above half, below half)
- [ ] Test: clip at 0 and 255
- [ ] Test: 1000 random acc/scale/shift combinations vs Python golden
- [ ] Verify: rounding is round-to-nearest-even (not truncation, not round-half-up)

### 5.4 Layer Controller Testbench (`testbench/layer_controller_tb.v`)
- [ ] Assert all FSM transitions using `$display` + error counter
- [ ] Verify no state persists > 1000 cycles (deadlock detection)
- [ ] Verify tile index increments correctly for multi-layer sequence

### 5.5 AXI4 Interface Testbenches
- [ ] AXI4-Lite: verify write and read transactions with VALID/READY toggling
- [ ] AXI4 Master (DMA): verify burst compliance, no protocol violations
- [ ] Use AXI4 protocol checker (Xilinx simulation IP or manual assertions)

### 5.6 End-to-End Co-Simulation (`testbench/top_level_tb.v`)
- [ ] Load test vectors from `testbench/test_vectors/` via `$readmemh()`
- [ ] Feed 10 complete test images through full accelerator pipeline
- [ ] Dump output to file via `$fwrite()`
- [ ] Run `python/compare_outputs.py` — verify bit-exact match for all 10 images
- [ ] Measure: clock cycles from first input to valid output (latency measurement)

### 5.7 Formal Verification (SymbiYosys)
- [ ] Write `formal/booth_mult.sby` — prove signed multiplication correctness
- [ ] Write `formal/layer_controller.sby` — prove FSM deadlock-free (BMC depth=200)
- [ ] Write `formal/axi4_lite.sby` — prove handshake liveness properties
- [ ] All formal checks: PASS

### 5.8 Coverage Targets (enforce before moving to Phase 6)
| Module | Statement | Branch | Toggle |
|--------|-----------|--------|--------|
| booth_mult | ≥95% | ≥90% | ≥85% |
| pe | ≥95% | ≥90% | ≥85% |
| quantize_scale | ≥95% | ≥95% | ≥85% |
| layer_controller | ≥95% | ≥90% | ≥80% |
| axi4_lite_slave | ≥95% | ≥90% | ≥80% |
| top-level | ≥90% | ≥85% | ≥75% |

---

## Phase 6: FPGA Synthesis, PnR & Validation

### 6.1 Synthesis
- [ ] Update `synthesis/scripts/synthesize_top.tcl` with all source files and XDC
- [ ] Set target: `xczu7ev-ffvc1156-2-e` (ZCU104)
- [ ] Run synthesis: zero critical warnings (resolve all `[Synth 8-*]` warnings)
- [ ] Check: no inferred latches in synthesis report
- [ ] Check: DSP inference confirmed for Booth multiplier (not LUT-based)

### 6.2 Timing Closure
- [ ] Target: 100 MHz (WNS ≥ 0 ns, TNS = 0 ns)
- [ ] If WNS < 0: identify critical path module from timing report
- [ ] Apply fixes in order (§6.2 risk mitigation from implementation plan)
- [ ] Document final achieved frequency in results table

### 6.3 Resource Utilization
- [ ] Record post-implementation: LUT, FF, BRAM, DSP, IO utilization
- [ ] Verify ≤ 20% LUT, ≤ 7% FF, ≤ 32% BRAM, ≤ 4% DSP (from estimates)
- [ ] If estimates exceeded, profile and optimize before hardware testing

### 6.4 Power Analysis
- [ ] Run post-implementation power report in Vivado
- [ ] Run XPE with switching activity from simulation (`.saif` file)
- [ ] Record: static power, dynamic power, total power
- [ ] Verify total ≤ 5W (portable device constraint)

### 6.5 Hardware Validation
- [ ] Program ZCU104 via JTAG
- [ ] Run 100 NIH ChestX-ray14 test images via PS DMA
- [ ] Compare hardware outputs vs golden model — verify 100% match
- [ ] Measure wall-clock latency: average ± std over 100 images
- [ ] Capture ILA traces: FSM state, AXI handshake, PE output
- [ ] Document any hardware-simulation discrepancies (investigate root cause)

---

## Phase 7: Benchmarking & Publication

### 7.1 Benchmarking
- [ ] Implement `python/benchmark.py`:
  - [ ] Automated latency measurement (100-image mean ± std)
  - [ ] Throughput calculation (images/sec)
  - [ ] TOPS calculation from operation count + latency
  - [ ] Energy/inference from power × latency
- [ ] Run all ablation studies (precision, array size, dataflow, QAT vs PTQ)
- [ ] Statistical analysis: bootstrap CI (n=1000) for all AUC-ROC values
- [ ] p-values: Wilcoxon signed-rank test (W4A8 vs FP32 per-class AUC-ROC)

### 7.2 Results Documentation
- [ ] Fill `docs/results.md` with all metric tables (reproducible from scripts)
- [ ] Comparison table vs Eyeriss, ShiDianNao, Angel-Eye, NVDLA
- [ ] Ablation study tables (4 ablations × metrics)

### 7.3 Paper Writing
- [ ] Draft Abstract (250 words, highlight TOPS/W and AUC-ROC)
- [ ] Draft Introduction with bulleted contributions
- [ ] Draft Related Work with survey table
- [ ] Draft Methodology (Quantization + Architecture sections)
- [ ] Draft Results with all figures (architecture diagram, timing diagram, results table)
- [ ] Draft Discussion (clinical relevance, limitations)
- [ ] Internal review cycle (supervisor feedback)
- [ ] Submit to target venue (IEEE TBioCAS — rolling deadline)

### 7.4 Open-Source Release
- [ ] Clean repository: remove all generated files, add `.gitignore`
- [ ] Add `README.md` with: requirements, how to train, how to simulate, how to synthesize
- [ ] Add `LICENSE` (MIT or Apache 2.0)
- [ ] Tag release: `v1.0.0` with paper DOI in release notes
- [ ] Verify: fresh clone + instructions reproduces all results