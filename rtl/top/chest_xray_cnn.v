// chest_xray_cnn.v
// Full-resolution chest X-ray binary classifier CNN.
// Target: 2048×2048 grayscale input, streaming 1 pixel/clock.
//
// Pipeline:
//
//  pixel_in (IMAGE_WIDTH×IMAGE_WIDTH, 8-bit, streaming)
//    │
//    ▼  conv_block_1  IMAGE_WIDTH=W1, N_FILTERS=8
//       3×3 × 8 filters  →  ReLU  →  2×2 MaxPool
//       out: 8-way pool, W2=(W1-2)/2 eff. width
//       inter-stage max-reduce → 1 ch (8-bit)
//    │
//    ▼  conv_block_2  IMAGE_WIDTH=W2, N_FILTERS=16
//       3×3 × 16 filters →  ReLU  →  2×2 MaxPool
//       out: 16-way pool, W3=(W2-2)/2 effective
//       inter-stage max-reduce → 1 ch
//    │
//    ▼  conv_block_3  IMAGE_WIDTH=W3, N_FILTERS=32
//    │
//    ▼  conv_block_4  IMAGE_WIDTH=W4, N_FILTERS=32
//    │
//    ▼  conv_block_5  IMAGE_WIDTH=W5, N_FILTERS=64
//       out: 64-way pool, TOTAL_OUTPUTS positions → ALL 64 channels kept
//    │
//    ▼  global_avg_pool  N_FILTERS=64, TOTAL_OUTPUTS
//       64 averages (8-bit each), serial output
//    │
//    ▼  fc_layer_1  N_IN=64, N_OUT=16  (time-muxed MAC + ReLU)
//    ▼  fc_layer_2  N_IN=16, N_OUT=1
//    ▼  threshold ≥ 128  →  class_out
//
// Default (production) IMAGE_WIDTH=2048:
//   W1=2048  W2=1023  W3=510  W4=254  W5=126
//   GAP_W=62  TOTAL_OUTPUTS=3844  SHIFT_BITS=12
//
// Simulation override (IMAGE_WIDTH=128):
//   W1=128  W2=63  W3=30  W4=14  W5=6
//   GAP_W=2  TOTAL_OUTPUTS=4  SHIFT_BITS=2
//
// ARM preprocessing (outside this module):
//   DICOM decode → grayscale → contrast stretch → AXI-S → pixel_in.
//
// Weights (demo):
//   Loaded from syn/weights/*.mem at elaboration.

`timescale 1ns/1ps

module chest_xray_cnn #(
    // ── Primary sizing parameter ─────────────────────────────────────────
    // Override to a smaller value (e.g. 128) for simulation.
    parameter IMAGE_WIDTH   = 2048,

    // ── Derived inter-stage widths ────────────────────────────────────────
    // Each stage: line-buffer width = output width of previous pool.
    // pool_out_width = (conv_out_width) / 2 = (IMAGE_WIDTH - 2) / 2
    parameter W2            = (IMAGE_WIDTH  - 2) / 2,
    parameter W3            = (W2           - 2) / 2,
    parameter W4            = (W3           - 2) / 2,
    parameter W5            = (W4           - 2) / 2,

    // ── Global-average-pool parameters ───────────────────────────────────
    // GAP_W: spatial size of the stage-5 pool output map
    parameter GAP_W         = (W5 - 2) / 2,
    // TOTAL_OUTPUTS: pool_valid pulses per frame fed into GAP
    parameter TOTAL_OUTPUTS = GAP_W * GAP_W,
    // SHIFT_BITS: right-shift for division.  2^12=4096 ≈ 3844 (prod);
    //             2^2=4 = 2*2 (sim with IMAGE_WIDTH=128).
    parameter SHIFT_BITS    = 12,
    parameter ACC_WIDTH     = 28
)(
    input  wire       clk,
    input  wire       rst_n,

    // Streaming pixel input (8-bit unsigned, 1 pixel/clock)
    input  wire [7:0] pixel_in,
    input  wire       pixel_valid,

    // Classification result (registered on inference_done)
    output reg        class_out,       // 0 = Normal, 1 = Abnormal
    output reg  [7:0] score,           // raw FC2 output (0..255)
    output reg        inference_done,  // 1-cycle pulse when result is ready

    // Busy flag: high while any FC layer is computing
    output wire       busy
);

    // =========================================================================
    // Stage 1: conv_block_1  IMAGE_WIDTH=W1, N_FILTERS=8
    // =========================================================================
    wire [8*8-1:0] cb1_pool_data;
    wire           cb1_pool_valid;

    conv_block #(
        .IMAGE_WIDTH(IMAGE_WIDTH),
        .N_FILTERS  (8),
        .WEIGHT_FILE("syn/weights/cb1_weights.mem")
    ) cb1 (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (pixel_in),
        .pixel_valid(pixel_valid),
        .pool_data  (cb1_pool_data),
        .pool_valid (cb1_pool_valid)
    );

    // Inter-stage max-reduce 1→2  (8 channels → 1)
    wire [7:0] stage1_out;
    max_reduce #(.N(8)) mr1 (
        .data_in (cb1_pool_data),
        .data_out(stage1_out)
    );

    // =========================================================================
    // Stage 2: conv_block_2  IMAGE_WIDTH=W2, N_FILTERS=16
    // =========================================================================
    wire [16*8-1:0] cb2_pool_data;
    wire            cb2_pool_valid;

    conv_block #(
        .IMAGE_WIDTH(W2),
        .N_FILTERS  (16),
        .WEIGHT_FILE("syn/weights/cb2_weights.mem")
    ) cb2 (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (stage1_out),
        .pixel_valid(cb1_pool_valid),
        .pool_data  (cb2_pool_data),
        .pool_valid (cb2_pool_valid)
    );

    // Inter-stage max-reduce 2→3  (16 → 1)
    wire [7:0] stage2_out;
    max_reduce #(.N(16)) mr2 (
        .data_in (cb2_pool_data),
        .data_out(stage2_out)
    );

    // =========================================================================
    // Stage 3: conv_block_3  IMAGE_WIDTH=W3, N_FILTERS=32
    // =========================================================================
    wire [32*8-1:0] cb3_pool_data;
    wire            cb3_pool_valid;

    conv_block #(
        .IMAGE_WIDTH(W3),
        .N_FILTERS  (32),
        .WEIGHT_FILE("syn/weights/cb3_weights.mem")
    ) cb3 (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (stage2_out),
        .pixel_valid(cb2_pool_valid),
        .pool_data  (cb3_pool_data),
        .pool_valid (cb3_pool_valid)
    );

    // Inter-stage max-reduce 3→4  (32 → 1)
    wire [7:0] stage3_out;
    max_reduce #(.N(32)) mr3 (
        .data_in (cb3_pool_data),
        .data_out(stage3_out)
    );

    // =========================================================================
    // Stage 4: conv_block_4  IMAGE_WIDTH=W4, N_FILTERS=32
    // =========================================================================
    wire [32*8-1:0] cb4_pool_data;
    wire            cb4_pool_valid;

    conv_block #(
        .IMAGE_WIDTH(W4),
        .N_FILTERS  (32),
        .WEIGHT_FILE("syn/weights/cb4_weights.mem")
    ) cb4 (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (stage3_out),
        .pixel_valid(cb3_pool_valid),
        .pool_data  (cb4_pool_data),
        .pool_valid (cb4_pool_valid)
    );

    // Inter-stage max-reduce 4→5  (32 → 1)
    wire [7:0] stage4_out;
    max_reduce #(.N(32)) mr4 (
        .data_in (cb4_pool_data),
        .data_out(stage4_out)
    );

    // =========================================================================
    // Stage 5: conv_block_5  IMAGE_WIDTH=W5, N_FILTERS=64
    //          No max-reduce: all 64 filter outputs go to GAP
    // =========================================================================
    wire [64*8-1:0] cb5_pool_data;
    wire            cb5_pool_valid;

    conv_block #(
        .IMAGE_WIDTH(W5),
        .N_FILTERS  (64),
        .WEIGHT_FILE("syn/weights/cb5_weights.mem")
    ) cb5 (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (stage4_out),
        .pixel_valid(cb4_pool_valid),
        .pool_data  (cb5_pool_data),
        .pool_valid (cb5_pool_valid)
    );

    // =========================================================================
    // Global Average Pooling  (64 filters, TOTAL_OUTPUTS positions)
    // Serial output: emits avg[0..63] one per clock after frame complete.
    // =========================================================================
    wire [7:0] gap_out_data;
    wire       gap_out_valid;

    global_avg_pool #(
        .N_FILTERS    (64),
        .TOTAL_OUTPUTS(TOTAL_OUTPUTS),
        .SHIFT_BITS   (SHIFT_BITS),
        .ACC_WIDTH    (ACC_WIDTH)
    ) gap (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (cb5_pool_data),
        .data_valid(cb5_pool_valid),
        .out_data  (gap_out_data),
        .out_valid (gap_out_valid)
    );

    // =========================================================================
    // FC layer 1:  64 → 16  (time-muxed MAC + ReLU)
    // =========================================================================
    wire [7:0] fc1_out;
    wire       fc1_valid;
    wire       fc1_busy;

    fc_layer #(
        .N_IN        (64),
        .N_OUT       (16),
        .WEIGHT_FILE ("syn/weights/fc1_weights.mem"),
        .BIAS_FILE   ("syn/weights/fc1_biases.mem")
    ) fc1 (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (gap_out_data),
        .data_valid(gap_out_valid),
        .data_out  (fc1_out),
        .out_valid (fc1_valid),
        .busy      (fc1_busy)
    );

    // =========================================================================
    // FC layer 2:  16 → 1
    // =========================================================================
    wire [7:0] fc2_out;
    wire       fc2_valid;
    wire       fc2_busy;

    fc_layer #(
        .N_IN        (16),
        .N_OUT       (1),
        .WEIGHT_FILE ("syn/weights/fc2_weights.mem"),
        .BIAS_FILE   ("syn/weights/fc2_biases.mem")
    ) fc2 (
        .clk       (clk),
        .rst_n     (rst_n),
        .data_in   (fc1_out),
        .data_valid(fc1_valid),
        .data_out  (fc2_out),
        .out_valid (fc2_valid),
        .busy      (fc2_busy)
    );

    assign busy = fc1_busy | fc2_busy;

    // =========================================================================
    // Threshold → binary decision
    //   score ≥ 128 → Abnormal (1), else Normal (0)
    // =========================================================================
    always @(posedge clk) begin
        if (!rst_n) begin
            class_out      <= 1'b0;
            score          <= 8'd0;
            inference_done <= 1'b0;
        end else begin
            inference_done <= 1'b0;
            if (fc2_valid) begin
                score          <= fc2_out;
                class_out      <= (fc2_out >= 8'd128) ? 1'b1 : 1'b0;
                inference_done <= 1'b1;
            end
        end
    end

endmodule


// =============================================================================
// max_reduce: combinational N-way 8-bit max  (used between conv_block stages)
// =============================================================================
module max_reduce #(
    parameter N = 8
)(
    input  wire [N*8-1:0] data_in,
    output reg  [7:0]     data_out
);
    integer i;
    always @(*) begin
        data_out = data_in[7:0];
        for (i = 1; i < N; i = i + 1)
            if (data_in[i*8 +: 8] > data_out)
                data_out = data_in[i*8 +: 8];
    end
endmodule
