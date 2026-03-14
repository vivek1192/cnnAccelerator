# CNN Accelerator Architecture
## Quantized CNN Accelerator for Medical Imaging — Detailed Hardware Architecture

---

## 1. System Overview

The accelerator is implemented on the **Xilinx Zynq UltraScale+ ZCU104** (xczu7ev-ffvc1156-2-e),
partitioned across the Processing System (PS) and Programmable Logic (PL):

```
┌──────────────────────────────────────────────────────────────────────┐
│                      ZCU104 SoC                                      │
│  ┌─────────────────────────┐    ┌─────────────────────────────────┐  │
│  │  Processing System (PS) │    │    Programmable Logic (PL)      │  │
│  │  ARM Cortex-A53 (4×)    │    │                                 │  │
│  │                         │    │  ┌─────────────────────────┐   │  │
│  │  ┌──────────────────┐   │AXI4│  │   CNN Accelerator       │   │  │
│  │  │ Linux / bare-metal│  │◄──►│  │   (cnn_accelerator.v)   │   │  │
│  │  │ driver            │   │    │  └─────────────────────────┘   │  │
│  │  └──────────────────┘   │    │                                 │  │
│  │                         │    │                                 │  │
│  │  ┌──────────────────┐   │AXI4│  ┌─────────────────────────┐   │  │
│  │  │ DMA Controller   │   │◄──►│  │   BRAM (448 KB total)   │   │  │
│  │  └──────────────────┘   │    │  └─────────────────────────┘   │  │
│  └─────────────────────────┘    └─────────────────────────────────┘  │
│                                                                        │
│  ┌────────────────────────────────────────────────────────────────┐   │
│  │                     DDR4 (4 GB)                                │   │
│  │  Model weights (~13 MB) | Feature maps (~25 MB) | OS image     │   │
│  └────────────────────────────────────────────────────────────────┘   │
└──────────────────────────────────────────────────────────────────────┘
```

**Clock**: Single clock domain, 100 MHz (target). All registers are positive-edge triggered.
**Reset**: Active-low synchronous reset (`rst_n`) — no asynchronous resets in PL.

---

## 2. Top-Level Accelerator Block Diagram

```
                          ┌─────────────────────────────────────────────┐
 AXI4-Lite (ctrl) ───────►│         axi4_lite_slave.v                   │
                          │  Register Map: start, status, layer_cfg,    │
                          │  weight_base_addr, act_base_addr,           │
                          │  scale_m[15:0], shift_n[3:0]               │
                          └──────────────────┬──────────────────────────┘
                                             │ config signals
                          ┌──────────────────▼──────────────────────────┐
 AXI4 (DMA read) ◄────────│         dma_engine.v                        │
                          │  AXI4 master: burst-reads weights &          │
                          │  activations from DDR4 → on-chip SRAMs      │
                          └──────────────────┬──────────────────────────┘
                                             │ write enables + data
             ┌────────────────┬──────────────▼──────────────┐
             │                │                             │
    ┌────────▼──────┐ ┌───────▼────────┐ ┌────────────────▼──────┐
    │ weight_sram.v │ │activation_sram │ │    output_sram.v       │
    │ 256 KB BRAM   │ │ 128 KB BRAM    │ │    64 KB BRAM          │
    └────────┬──────┘ └───────┬────────┘ └────────────────┬──────┘
             │                │                             ▲
        weights[4]     activations[8]                  acc_out[24]
             │                │                             │
             └────────────────▼─────────────────────────────┤
                       ┌──────────────────┐                 │
                       │   pe_array.v     │─────────────────┘
                       │   8×8 PE array   │
                       │   64 × pe.v      │
                       └──────────┬───────┘
                                  │ acc_out (post-tile)
                       ┌──────────▼───────┐
                       │ quantize_scale.v  │
                       │ relu.v            │
                       │ max_pool.v        │
                       └──────────┬───────┘
                                  │ 8-bit output
                       ┌──────────▼───────────────┐
                       │   layer_controller.v      │
                       │   FSM: orchestrates all   │
                       │   tile/layer iterations   │
                       └───────────────────────────┘
```

---

## 3. Dataflow: Output-Stationary (OS)

### 3.1 Tiling Strategy
For a convolutional layer with input `H_in × W_in × C_in` and filters `K × K × C_in × C_out`:

```
Tile dimensions:
  T_h = tile height     (output spatial, fit in output buffer)
  T_w = tile width      (output spatial, fit in output buffer)
  T_c_out = 8           (output channels per PE column)
  T_c_in  = 8           (input channels per PE row)

Tile iteration order (outermost to innermost):
  for tile_oc in range(0, C_out, T_c_out):       ← output channel tiles
    for tile_oh in range(0, H_out, T_h):         ← output row tiles
      for tile_ow in range(0, W_out, T_w):       ← output col tiles
        for tile_ic in range(0, C_in, T_c_in):  ← input channel tiles
          COMPUTE: 8×8 PEs accumulate partial sums
        END  ← drain output buffer after all input channels processed
```

### 3.2 PE Array Data Reuse
In output-stationary mode:
- **Weight reuse**: Each weight is broadcast to all 8 PEs in a column simultaneously
- **Activation reuse**: Each activation is broadcast to all 8 PEs in a row simultaneously
- **Partial sums**: Stay in PE accumulators for entire input-channel iteration — never written to SRAM mid-tile

```
PE Array (8×8):
         col0   col1   col2   col3   col4   col5   col6   col7
         [oc0]  [oc1]  [oc2]  [oc3]  [oc4]  [oc5]  [oc6]  [oc7]
row0 [ic0]  PE    PE    PE    PE    PE    PE    PE    PE   ← activation[ic0] broadcast across row
row1 [ic1]  PE    PE    PE    PE    PE    PE    PE    PE
row2 [ic2]  PE    PE    PE    PE    PE    PE    PE    PE
row3 [ic3]  PE    PE    PE    PE    PE    PE    PE    PE
row4 [ic4]  PE    PE    PE    PE    PE    PE    PE    PE
row5 [ic5]  PE    PE    PE    PE    PE    PE    PE    PE
row6 [ic6]  PE    PE    PE    PE    PE    PE    PE    PE
row7 [ic7]  PE    PE    PE    PE    PE    PE    PE    PE
              ↑
         weight[oc0, ic_row] broadcast down each column
```

---

## 4. Processing Element (PE) Internal Architecture

```
        weight_i[3:0]         activation_i[7:0]
             │                       │
    ┌────────▼──────────┐   ┌────────▼──────────┐
    │  Weight Reg File  │   │  Act Reg File      │
    │  8 × 4-bit regs   │   │  4 × 8-bit regs    │
    └────────┬──────────┘   └────────┬──────────┘
             │                       │
             └───────────┬───────────┘
                         │
               ┌─────────▼──────────┐
               │   booth_mult.v     │
               │  signed 4-bit ×    │
               │  unsigned 8-bit    │
               │  → 12-bit product  │
               │  (2-cycle pipeline)│
               └─────────┬──────────┘
                         │ product[11:0]
               ┌─────────▼──────────┐
               │  Sign Extend       │
               │  12-bit → 24-bit   │
               └─────────┬──────────┘
                         │
               ┌─────────▼──────────┐
               │  24-bit Saturating │◄── acc_clear_i (sync)
               │  Accumulator       │
               │  clamp at 24'h7FFFFF│
               └─────────┬──────────┘
                         │ acc_out[23:0]
                         ▼
                  (to quantize_scale.v when acc_valid_o asserted)
```

**Accumulator Saturation Logic**:
```verilog
// Positive overflow: product is positive and acc near max
if (!sign_of_sum && acc_r[23]) // was positive, result wrapped negative
    acc_r <= 24'h7FFFFF;       // saturate to max positive
// Negative: not needed — unsigned activations × signed weights,
// negative results indicate inhibition, clamped to 0 by ReLU post-scaling
else
    acc_r <= sum[23:0];
```

---

## 5. Booth Multiplier Architecture

**Spec**: Radix-2 Booth, 2-stage pipeline, signed 4-bit × unsigned 8-bit → 12-bit

```
Stage 1 (cycle N):   Compute partial products using Booth recoding of weight[3:0]
Stage 2 (cycle N+1): Wallace tree reduction → final 12-bit product

Booth Recoding (4-bit weight, process pairs with overlap):
  bit pairs: {weight[1:0], 0}, {weight[3:2], weight[1]}
  Each pair → {-2, -1, 0, +1, +2} × activation
  Sum of 2 partial products → 12-bit result (no overflow: 2^3 × 2^8 = 2^11 + sign = 12-bit)

Pipeline registers:
  Stage 1 output: partial_pp0[11:0], partial_pp1[11:0] — registered
  Stage 2 output: product[11:0] — registered (module output)
```

---

## 6. Memory Architecture

### 6.1 Weight SRAM (256 KB)
```
Organization: 256K × 8-bit (but weights are 4-bit, so packed 2-per-byte)
              → 256K × 4-bit effective = 512K 4-bit weight storage
Addressing:   byte-addressed, 17-bit address (2^17 = 128K addresses × 2 weights/byte)
Port A:       write from DMA engine (64-bit wide, 8 beats per burst word)
Port B:       read to PE array (64-bit wide = 16 × 4-bit weights per cycle → 2 cycles per 8-col fill)
BRAM count:   256 KB / 36 Kb = ~57 BRAM36 tiles
```

### 6.2 Activation SRAM (128 KB)
```
Organization: 128K × 8-bit
Port A:       write from DMA engine or output_sram (ping-pong buffering)
Port B:       read to PE array (64-bit wide = 8 activations per cycle → 1 cycle per 8-row fill)
BRAM count:   128 KB / 36 Kb = ~29 BRAM36 tiles
```

### 6.3 Output SRAM (64 KB)
```
Organization: 64K × 8-bit (stores 8-bit clipped outputs after quantize_scale + relu)
Port A:       write from quantize_scale → relu pipeline
Port B:       read by DMA engine (write back to DDR4) or feed to next layer activation SRAM
BRAM count:   64 KB / 36 Kb = ~15 BRAM36 tiles
Total BRAMs:  ~101 BRAM36 tiles (of 312 available on ZCU104 = 32% utilization)
```

### 6.4 Ping-Pong Buffering
To overlap compute and memory transfer:
```
Buffer A: being read by PE array (compute)
Buffer B: being written by DMA engine (prefetch next tile)
After compute: swap A and B (double-buffer pointer swap, 0-cycle overhead)
```

---

## 7. Layer Controller FSM

```
                    ┌─────┐
          rst_n ───►│IDLE │
                    └──┬──┘
                       │ start
              ┌────────▼──────────┐
              │   LOAD_CONFIG     │ Read layer params from AXI4-Lite regs
              └────────┬──────────┘
                       │
              ┌────────▼──────────┐
        ┌────►│  FETCH_WEIGHTS    │ Issue DMA read for weight tile → weight SRAM
        │     └────────┬──────────┘
        │              │ dma_done
        │     ┌────────▼──────────┐
        │     │  FETCH_ACTIVATIONS│ Issue DMA read for activation tile → act SRAM
        │     └────────┬──────────┘
        │              │ dma_done
        │     ┌────────▼──────────┐
        │     │  COMPUTE_TILE     │ Enable PE array, wait for acc_valid from all PEs
        │     └────────┬──────────┘
        │              │ all_pes_valid
        │     ┌────────▼──────────┐
        │     │  DRAIN_OUTPUT     │ quantize_scale → relu → write output SRAM
        │     └────────┬──────────┘
        │              │ drain_done
        │     ┌────────▼──────────┐
        │     │  NEXT_TILE        │ Increment tile_row/col/channel counters
        │     └────────┬──────────┘
        │              │
        │    ┌─────────┴─────────┐
        │    │ more tiles?        │
        │    └──┬────────────┬───┘
        └───YES─┘            │NO
                    ┌────────▼──────────┐
                    │   NEXT_LAYER      │ Increment layer_id, reload config
                    └────────┬──────────┘
                             │
                   ┌─────────┴─────────┐
                   │ more layers?       │
                   └──┬────────────┬───┘
          (loop back YES)          │NO
                          ┌────────▼──────────┐
                          │     DONE          │ Assert done_irq_o
                          └───────────────────┘
```

---

## 8. Post-Accumulation Pipeline

After PE array drains, each 24-bit accumulator value passes through:

```
acc[23:0]
    │
    ▼
┌──────────────────────────────────────────────────┐
│ quantize_scale.v                                  │
│                                                   │
│  Step 1: Multiply   temp[39:0] = acc × scale_m   │
│  Step 2: Shift      temp       = temp >> shift_n  │
│  Step 3: Round      round-to-nearest-even         │
│  Step 4: Clip       out[7:0]   = clip(temp, 0, 255)│
└──────────────────────┬───────────────────────────┘
                       │ out[7:0]
                       ▼
              ┌────────────────┐
              │   relu.v       │  out = (in[7]) ? 0 : in  (already clipped ≥0 by quantize)
              └────────┬───────┘  Note: after unsigned clip, relu is always pass-through
                       │          unless negative values from depthwise convolutions
                       ▼
              ┌────────────────┐
              │  max_pool.v    │  2×2 window, stride 2, streaming
              │  (optional)    │
              └────────┬───────┘
                       │ out[7:0]
                       ▼
                  output_sram.v
```

---

## 9. AXI4 Interface Specification

### 9.1 AXI4-Lite Register Map (base address: 0xA000_0000)

| Offset | Register | Width | Access | Description |
|--------|----------|-------|--------|-------------|
| 0x00 | CTRL | 32 | W | bit[0]: start; bit[1]: reset |
| 0x04 | STATUS | 32 | R | bit[0]: done; bit[1]: running; bit[2]: error |
| 0x08 | LAYER_COUNT | 32 | W | Number of layers to process |
| 0x0C | CURRENT_LAYER | 32 | R | Current layer index (debug) |
| 0x10 | WEIGHT_BASE_ADDR | 32 | W | DDR4 base address of weight tensor |
| 0x14 | ACT_BASE_ADDR | 32 | W | DDR4 base address of activation tensor |
| 0x18 | SCALE_M | 32 | W | bits[15:0]: scale multiplier M |
| 0x1C | SHIFT_N | 32 | W | bits[3:0]: shift amount N |
| 0x20 | IN_CHANNELS | 32 | W | Input channels for current layer |
| 0x24 | OUT_CHANNELS | 32 | W | Output channels for current layer |
| 0x28 | IN_HEIGHT | 32 | W | Input feature map height |
| 0x2C | IN_WIDTH | 32 | W | Input feature map width |

### 9.2 AXI4 Master (DMA) Parameters
```
Data width:      64-bit (8 bytes per beat)
Address width:   32-bit
Burst type:      INCR (incrementing)
Max burst len:   256 beats (ARLEN = 255) = 2 KB per burst
ID width:        4-bit (supports up to 16 outstanding transactions)
Cache:           Normal Non-cacheable Bufferable (0b0011)
Protection:      Non-secure, Non-privileged, Data (0b000)
```

---

## 10. Timing Budget Analysis

At 100 MHz (10 ns period), critical path budget per stage:

| Stage | Dominant Logic | Estimated Delay | Budget |
|-------|---------------|-----------------|--------|
| FETCH_W | SRAM read + register | 4.5 ns | 10 ns |
| FETCH_A | SRAM read + register | 4.5 ns | 10 ns |
| COMPUTE (Stage 1) | Booth partial products | 6.5 ns | 10 ns |
| COMPUTE (Stage 2) | Wallace tree + register | 5.0 ns | 10 ns |
| ACCUMULATE | 24-bit adder + saturation mux | 5.5 ns | 10 ns |
| WRITEBACK | quantize multiply (40-bit) | 7.5 ns | 10 ns ← tightest |

**Note**: The quantize_scale multiply is the critical path candidate. If timing fails, pipeline
the 40-bit multiply into 2 stages (accept +1 cycle latency in drain pipeline).