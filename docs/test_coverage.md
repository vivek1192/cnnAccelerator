# Verification & Test Coverage Strategy
## PhD-Level Hardware Verification Plan

---

## 1. Verification Philosophy

This project employs a **layered verification strategy** combining:
1. **Unit simulation** — directed + constrained-random per module
2. **Golden model co-simulation** — bit-exact numerical equivalence
3. **Formal verification** — property-based proofs on FSM and protocol compliance
4. **Hardware-in-the-loop** — physical validation on ZCU104

Coverage is a *means*, not an end. The exit criterion for each phase is:
**"The module behaves correctly for all inputs the system will present in real operation,
including all edge cases documented in the design specification."**

---

## 2. Coverage Targets

### 2.1 Code Coverage (enforced before synthesis)

| Module | Statement | Branch | Toggle | Condition |
|--------|-----------|--------|--------|-----------|
| `booth_mult.v` | ≥98% | ≥95% | ≥90% | ≥90% |
| `pe.v` | ≥95% | ≥90% | ≥85% | ≥85% |
| `quantize_scale.v` | ≥98% | ≥95% | ≥90% | ≥95% |
| `relu.v` | 100% | 100% | 100% | 100% |
| `max_pool.v` | ≥95% | ≥90% | ≥85% | ≥85% |
| `layer_controller.v` | ≥95% | ≥90% | ≥80% | ≥85% |
| `pe_array.v` | ≥90% | ≥85% | ≥80% | ≥80% |
| `axi4_lite_slave.v` | ≥95% | ≥90% | ≥85% | ≥90% |
| `dma_engine.v` | ≥90% | ≥85% | ≥80% | ≥80% |
| Top-level integration | ≥90% | ≥85% | ≥75% | ≥80% |

**Tool**: Icarus Verilog + custom coverage scripts, or Verilator `--coverage`.

### 2.2 Functional Coverage (explicitly verified, not tool-measured)

| Feature | Coverage Points | Method |
|---------|----------------|--------|
| Booth multiplier: all sign combinations | (+×+), (+×−), (−×+), (−×−) | Directed test |
| Booth multiplier: boundary values | weight=−8, weight=7, act=0, act=255 | Directed test |
| Accumulator: saturation | force overflow, verify clamp | Directed test |
| Accumulator: zero | all-zero input, 100 cycles | Directed test |
| Quantize: rounding modes | below-half, exact-half-even, exact-half-odd, above-half | Directed test |
| Quantize: clip at 255 | large positive accumulator → verify output=255 | Directed test |
| Quantize: clip at 0 | negative accumulator (after signed mult) → verify output=0 | Directed test |
| ReLU: positive passthrough | all 256 possible input values | Exhaustive |
| ReLU: negative block (zero output) | negative input after sign extension | Directed test |
| Max pool: all positions win | corner, edge, center all produce maximum | Directed test |
| Max pool: window boundary | last pixel in row/column | Directed test |
| FSM: all state transitions | ≥1 traversal of each edge | Assertion coverage |
| FSM: multi-layer sequence | 5 consecutive layers | System test |
| AXI4-Lite: write then read | write reg, read back same value | Protocol test |
| AXI4-Lite: simultaneous valid | AWVALID and WVALID same cycle | Corner case |
| AXI master: READY de-assert | target stalls (RREADY=0), verify no data loss | Back-pressure test |
| End-to-end: correct output | 100 NIH CXR14 test images | Co-simulation |

---

## 3. Module-Level Testbenches

### 3.1 `testbench/booth_mult_tb.v`

**Purpose**: Verify correctness of signed 4-bit × unsigned 8-bit Booth multiplier.

**Test plan**:
```
Test 1 — Exhaustive (all 4096 combinations):
  for weight in range(-8, 8):         // 4-bit signed: -8 to +7
    for activation in range(0, 256):  // 8-bit unsigned: 0 to 255
      expected = weight * activation  // Python reference
      simulate, wait 2 cycles (pipeline latency)
      assert dut_output == expected[11:0]
  PASS criterion: 0 mismatches

Test 2 — Pipeline timing:
  Apply input at cycle N
  Assert output_valid_o is LOW at cycle N, N+1
  Assert output_valid_o is HIGH at cycle N+2
  Assert product_o is stable while output_valid_o is HIGH

Test 3 — Back-to-back throughput:
  Apply new inputs every cycle (no pipeline stalls)
  Verify outputs emerge every cycle after initial 2-cycle latency
  Verify no pipeline bubble or result corruption

Test 4 — Reset behavior:
  Assert rst_n during computation
  Verify pipeline flushes within 1 cycle
  Verify output_valid_o de-asserts within 1 cycle of rst_n assertion
```

**Expected coverage**: Statement 98%, Branch 95% (unreachable: default cases in Booth FSM).

---

### 3.2 `testbench/pe_tb.v`

**Purpose**: Verify PE accumulation, saturation, and clear behavior.

**Test plan**:
```
Test 1 — Basic accumulation (directed):
  Load weight = 4'h3 (+3), activation = 8'hFF (255)
  Accumulate 10 cycles
  Expected: acc = 10 × 3 × 255 = 7,650 = 24'h000_1DE2
  Assert acc_out == 24'h1DE2 when acc_valid_o asserted

Test 2 — Saturation (corner case):
  Load weight = 4'h7 (+7), activation = 8'hFF (255)
  Accumulate until theoretical overflow: 7×255 = 1785, repeat 9396 times > 2^24
  In practice: accumulate 10000 cycles
  Assert acc_out == 24'h7FFFFF (saturated, not wrapped)
  CRITICAL: if acc_out < 24'h7FFFFF after expected overflow → saturation bug

Test 3 — acc_clear timing:
  Accumulate 5 cycles (acc non-zero)
  Assert acc_clear_i for 1 cycle
  Assert acc_out == 0 at next posedge clk (synchronous clear)
  Assert acc_valid_o de-asserts during clear

Test 4 — Zero input:
  Load weight = 0, activation = 0
  Accumulate 100 cycles
  Assert acc_out == 0 throughout

Test 5 — Negative weight:
  Load weight = 4'hF (-1 in 4-bit signed two's complement)
  Load activation = 8'h0A (10)
  Accumulate 5 cycles
  Expected: acc = 5 × (−1) × 10 = −50 (stored as 24-bit two's complement: 24'hFFFFCE)
  Assert acc_out == 24'hFFFFCE

Test 6 — Random constrained (1000 iterations):
  weight = $random % 16 (4-bit range)
  activation = $random % 256 (8-bit range)
  n_cycles = $random % 64 + 1
  expected = Python golden computation
  Assert bit-exact match
```

---

### 3.3 `testbench/quantize_scale_tb.v`

**Purpose**: Verify scale-shift-round-clip operation with exact rounding mode.

**Test plan**:
```
Test 1 — Rounding modes (directed, 4 cases):
  Case A: result below half → truncate
    acc=100, M=3277, N=4  → (100×3277)>>4 = 327700>>4 = 20481.25 → round to 20481
  Case B: result above half → round up
    acc=101, M=3277, N=4  → (101×3277)>>4 = 330977>>4 = 20686.0625 → 20686... wait
    [Use specific values where bit patterns are known to test each rounding case]
  Case C: exactly half, result even → keep (RNE rule)
  Case D: exactly half, result odd → round up (RNE rule)
  Compare each case against Python: int(round(float(acc*M) / float(2**N))) using RNE

Test 2 — Clip at 255:
  acc = 24'h7FFFFF (max), M = 16'hFFFF, N = 0
  Assert output == 8'hFF (255)

Test 3 — Clip at 0:
  acc = 24'h800000 (large negative in two's complement signed)
  Assert output == 8'h00 (0) — negative values clipped to 0 before relu

Test 4 — Scale=1, Shift=0 (identity for small values):
  acc = 100, M = 1, N = 0
  Expected output = clip(100, 0, 255) = 100
  Assert output == 8'd100

Test 5 — Random (10,000 iterations):
  acc = $random % (1 << 24)
  M = $random % (1 << 16)
  N = $random % 16
  expected = Python: clip(round_half_to_even((acc * M) >> N), 0, 255)
  Assert bit-exact match
```

---

### 3.4 `testbench/layer_controller_tb.v`

**Purpose**: Verify FSM correctness, tile iteration, and multi-layer sequencing.

**Assertions** (use `assert` in Verilog or `$fatal` checks):
```verilog
// No state persists > 1000 cycles
always @(posedge clk) begin
    state_timer <= state_timer + 1;
    if (state != prev_state) state_timer <= 0;
    if (state_timer > 1000) $fatal("FSM deadlock detected in state %0d", state);
end

// Tile index never exceeds layer dimensions
always @(posedge clk) begin
    if (tile_row_r >= out_height_r / T_h + 1)
        $fatal("tile_row out of bounds: %0d", tile_row_r);
end

// done_irq_o only asserted in DONE state
always @(posedge clk) begin
    if (done_irq_o && state != DONE)
        $fatal("done_irq asserted in wrong state: %0d", state);
end
```

**Test plan**:
```
Test 1 — Single layer, single tile:
  Configure: in_h=8, in_w=8, in_c=8, out_c=8, kernel=1
  Start FSM
  Verify state sequence: IDLE→LOAD_CONFIG→FETCH_WEIGHTS→FETCH_ACT→COMPUTE→DRAIN→DONE
  Verify done_irq_o asserts exactly once
  Verify all intermediate signals correct at each state

Test 2 — Single layer, multiple tiles:
  Configure: in_h=28, in_w=28, in_c=64, out_c=16
  Verify tile_row/col iterate through all positions
  Verify SRAM addresses increment correctly per tile

Test 3 — Multiple layers (5 layers):
  Configure 5 consecutive layers with different dimensions
  Verify layer_id increments after each DONE→NEXT_LAYER transition
  Verify done_irq_o only fires after all 5 layers complete

Test 4 — Reset during operation:
  Start FSM, assert rst_n during COMPUTE state
  Verify FSM returns to IDLE within 1 cycle
  Verify all tile counters cleared
```

---

### 3.5 `testbench/top_level_tb.v`

**Purpose**: End-to-end co-simulation with golden model comparison.

```
Simulation flow:
1. Initialize:
   $readmemh("testbench/test_vectors/layer_0_weights.hex", weight_sram_model);
   $readmemh("testbench/test_vectors/layer_0_activations.hex", act_sram_model);

2. Configure via AXI4-Lite:
   Write WEIGHT_BASE_ADDR, ACT_BASE_ADDR, SCALE_M, SHIFT_N, layer dimensions
   Write CTRL[0] = 1 (start)

3. Wait for done_irq_o

4. Read output_sram via AXI4-Lite and dump to file:
   $fopen("testbench/test_vectors/rtl_output_layer_0.hex", "w");
   // write each output byte

5. External comparison (post-simulation):
   python compare_outputs.py \
     testbench/test_vectors/golden_output_layer_0.hex \
     testbench/test_vectors/rtl_output_layer_0.hex
   → PASS/FAIL with mismatch count and first mismatch location

Test images: 10 images from NIH ChestX-ray14 test set
             (distinct patient IDs not in training set)
Criterion: 0 bit mismatches across all 10 images, all layers
```

---

## 4. Formal Verification

### 4.1 Tool: SymbiYosys (open-source, Yosys-based)
Alternative: Cadence JasperGold (if university license available).

### 4.2 Properties to Prove

**`formal/booth_mult.sby` — Multiplier Correctness**:
```
Property 1 (Correctness): For all inputs (w[3:0], a[7:0]):
  after 2 clock cycles, product_o == $signed(w) * $unsigned(a)

Property 2 (Pipeline stability): product_o is stable between valid assertions:
  if (valid_i_r0 && !valid_i) → product_o unchanged until next valid_i

Proof method: Bounded Model Checking, depth=10 (sufficient for 2-cycle pipeline)
```

**`formal/layer_controller.sby` — Liveness and Safety**:
```
Property 1 (Liveness): Starting from IDLE with start=1, eventually done_irq_o=1:
  (state==IDLE && start) |-> ##[1:10000] done_irq_o
  Proof method: k-induction or BMC depth=200

Property 2 (Safety): done_irq_o only in DONE state:
  always: done_irq_o → (state==DONE)
  Proof method: BMC depth=50

Property 3 (Safety): No state lasts more than MAX_WAIT cycles:
  always: (state==FETCH_WEIGHTS && !dma_done) → ##[1:256] dma_done
  Proof method: BMC depth=300 (upper bound on DMA burst)

Property 4 (Safety): FSM is reset-safe:
  (!rst_n) |=> (state==IDLE && tile_row==0 && tile_col==0)
  Proof method: BMC depth=2
```

**`formal/axi4_lite.sby` — Protocol Compliance**:
```
Property 1 (Handshake liveness): If AWVALID asserted, AWREADY asserted within N cycles:
  AWVALID |-> ##[0:16] AWREADY

Property 2 (No spurious responses): BVALID only after completed write transaction:
  BVALID |-> $past(AWVALID && AWREADY && WVALID && WREADY)

Property 3 (Read data stability): RDATA stable while RVALID && !RREADY:
  (RVALID && !RREADY) |=> $stable(RDATA)
```

---

## 5. Regression Test Suite

### 5.1 Automated Regression (`Makefile` targets)
```makefile
test_unit:       ## Run all unit testbenches
    iverilog -o sim/booth_mult_tb  testbench/booth_mult_tb.v  hardware/booth_mult.v
    iverilog -o sim/pe_tb          testbench/pe_tb.v          hardware/pe.v hardware/booth_mult.v
    iverilog -o sim/quant_tb       testbench/quantize_scale_tb.v hardware/quantize_scale.v
    iverilog -o sim/ctrl_tb        testbench/layer_controller_tb.v hardware/layer_controller.v
    for tb in sim/*_tb; do vvp $$tb | tee logs/$$(basename $$tb).log; done
    grep -l "FAIL\|Error\|fatal" logs/ && exit 1 || echo "All unit tests PASSED"

test_integration: ## Run end-to-end co-simulation
    iverilog -o sim/top_tb testbench/top_level_tb.v hardware/*.v
    vvp sim/top_tb
    python python/compare_outputs.py testbench/test_vectors/golden/ testbench/test_vectors/rtl_out/

test_formal:     ## Run SymbiYosys formal checks
    sby -f formal/booth_mult.sby
    sby -f formal/layer_controller.sby
    sby -f formal/axi4_lite.sby

test_all: test_unit test_integration test_formal
    echo "Full regression PASSED"
```

### 5.2 Regression Policy
- All tests must pass before any commit to the `main` branch
- `test_unit` must run in < 10 minutes (gate for fast iteration)
- `test_integration` may run up to 2 hours (run before pull request merge)
- `test_formal` may run up to 4 hours (run weekly or before major milestones)
- A failing test blocks synthesis — synthesis on broken RTL wastes hours

---

## 6. Known Bugs in Current RTL (to fix before re-testing)

| Module | File | Line | Bug | Fix Required |
|--------|------|------|-----|-------------|
| `relu.v` | hardware/relu.v | 8 | `if (in > 8'b0)` — compares 16-bit to 8-bit, always extends incorrectly | Change to `if (!in[15])` (check sign bit) |
| `max_pool.v` | hardware/max_pool.v | 24 | `integer i` not synthesizable; blocking `=` inside clocked `always` | Replace with `reg [2:0] count_r`, use `<=` |
| `max_pool.v` | hardware/max_pool.v | 24 | `i` never initialized in reset | Add `count_r <= 0` in reset branch |
| `conv_layer_impl.v` | hardware/layers/conv_layer_impl.v | 13 | `OUTPUT_WIDTH`, `OUTPUT_HEIGHT` undefined parameters | Define as `INPUT_WIDTH - FILTER_SIZE + 1` etc. |
| `conv_layer_impl.v` | hardware/layers/conv_layer_impl.v | 17 | Empty implementation stub | Replace with MAC loop using `booth_mult` |
| `booths_multiplier.v` | booths_multiplier.v | 16 | Bit ordering: `{multiplier[0], multiplier[1]}` is reversed | Should be `{multiplier[1], multiplier[0]}` for Booth recoding |
| `booths_multiplier.v` | booths_multiplier.v | 24 | `multiplier = {multiplier[6:0], 1'b0}` — left shift loses MSB, wrong for Booth | Booth requires right shift of multiplier |
| `booths_multiplier.v` | booths_multiplier.v | 28 | `product = acc[8:1]` — truncates 16-bit product to 8-bit incorrectly | Booth for 8×8 needs 16-bit acc output |

**Priority**: Fix all bugs above before writing any new testbenches — testing against broken
RTL produces false negative results that waste verification time.

---

## 7. Simulation Infrastructure Requirements

### 7.1 Tools
- **Icarus Verilog** (iverilog/vvp): functional simulation, unit testbenches
- **GTKWave**: waveform visualization for debugging
- **Verilator** (optional): faster simulation for long random tests (>100K cycles)
- **SymbiYosys**: formal verification (install: `pip install symbiyosys`)
- **Python 3.10+**: golden model, test vector generation, comparison scripts

### 7.2 Test Vector Format
```
File naming: testbench/test_vectors/layer_{N}_{type}.hex
  where N = layer index (0-based), type ∈ {weights, activations, output_golden, output_rtl}

Format: One hexadecimal value per line, zero-padded to fixed width
  4-bit weights:   1 hex digit per line (e.g., "A\n" for 4'hA)
  8-bit values:    2 hex digits per line (e.g., "FF\n" for 8'hFF)
  24-bit accum:    6 hex digits per line (e.g., "001DE2\n")

Loaded in Verilog:  $readmemh("path/to/file.hex", memory_array);
Written in Verilog: $fwrite(fd, "%02X\n", signal);
Read in Python:     values = [int(line.strip(), 16) for line in open("file.hex")]
```

### 7.3 Simulation Time Budget
| Testbench | Estimated sim time | Max allowed |
|-----------|-------------------|-------------|
| booth_mult exhaustive | ~30 seconds | 5 minutes |
| pe_tb (1000 random) | ~1 minute | 10 minutes |
| quantize_scale (10K random) | ~2 minutes | 10 minutes |
| layer_controller (5 layers) | ~5 minutes | 20 minutes |
| top_level (10 images) | ~60 minutes | 2 hours |