// conv_block.v
// Multi-filter convolutional block for large-image streaming CNN.
//
// Architecture (one block):
//   N_FILTERS parallel conv_layer instances share the same pixel_in stream.
//   Each filter has its own 3×3 weight set, produces its own feature map.
//   Each filter's output passes through relu → max_pool.
//   All N_FILTERS pool outputs are packed into a flat bus.
//
// Inter-block connections:
//   - Intermediate blocks: the top-level max-reduces pool_data to a single
//     8-bit value that feeds the next block's pixel_in.
//   - Last block (block 5): pool_data is passed directly to global_avg_pool.
//
// Line buffers:
//   Each conv_layer instance manages its own two delay-line arrays.
//   For IMAGE_WIDTH >= 512, Vivado infers RAMB36E2 (via ram_style="block"
//   attribute in conv_layer.v).  Each filter uses one RAMB36E2 for both
//   delay lines (2 × IMAGE_WIDTH bytes ≤ 4 KB for IMAGE_WIDTH ≤ 2048).
//
// Weight ROM:
//   Flat array of N_FILTERS × 9 signed 8-bit entries, loaded via $readmemh.
//   Filter f occupies addresses f*9 .. f*9+8 (row-major, left-to-right,
//   top-to-bottom):  [0]=top-left … [8]=bottom-right.
//
// Output timing:
//   pool_valid is asserted for 1 cycle every 4 conv-valid cycles.
//   All N_FILTERS pool_valid signals fire simultaneously (shared data_valid).
//
// Latency:
//   Same as conv_layer: 2 rows + 2 column taps + pool accumulation.
//
// Parameters:
//   IMAGE_WIDTH  — pixel columns in the input stream (line-buffer depth).
//   N_FILTERS    — number of parallel 3×3 conv filters.
//   WEIGHT_FILE  — $readmemh path, N_FILTERS×9 8-bit signed hex values.

module conv_block #(
    parameter IMAGE_WIDTH = 2048,
    parameter N_FILTERS   = 8,
    parameter WEIGHT_FILE = "syn/weights/cb1_weights.mem"
)(
    input  wire                      clk,
    input  wire                      rst_n,

    // Streaming input (1 pixel per clock, valid handshake)
    input  wire [7:0]                pixel_in,
    input  wire                      pixel_valid,

    // Packed output: pool_data[f*8 +: 8] = 8-bit pool result for filter f.
    // All N_FILTERS values are valid simultaneously when pool_valid=1.
    output reg  [N_FILTERS*8-1:0]   pool_data,
    output reg                       pool_valid
);

    // ── Weight ROM ────────────────────────────────────────────────────────────
    // N_FILTERS × 9 signed 8-bit weights.
    // rom_style="auto" lets Vivado choose distributed or block RAM per size.
    (* rom_style = "auto" *)
    reg signed [7:0] w_rom [0:N_FILTERS*9-1];

    initial begin
        if (WEIGHT_FILE != "") $readmemh(WEIGHT_FILE, w_rom);
    end

    // ── Pack weights for each filter into 72-bit conv_layer weight bus ────────
    // weights_f[f][k*8 +: 8] = w_rom[f*9 + k]
    wire [71:0] weights_f [0:N_FILTERS-1];

    genvar f, k;
    generate
        for (f = 0; f < N_FILTERS; f = f + 1) begin : PACK_W
            for (k = 0; k < 9; k = k + 1) begin : PACK_K
                assign weights_f[f][k*8 +: 8] = w_rom[f*9 + k];
            end
        end
    endgenerate

    // ── N_FILTERS conv_layer instances (each with own line buffers) ───────────
    wire [15:0] fm_out   [0:N_FILTERS-1];   // 16-bit signed conv result
    wire        cv_valid [0:N_FILTERS-1];   // conv valid (all identical)

    generate
        for (f = 0; f < N_FILTERS; f = f + 1) begin : CONV_F
            conv_layer #(
                .IMAGE_WIDTH(IMAGE_WIDTH),
                .FILTER_SIZE(3)
            ) cl_inst (
                .clk            (clk),
                .rst_n          (rst_n),
                .pixel_in       (pixel_in),
                .pixel_valid    (pixel_valid),
                .weights        (weights_f[f]),
                .feature_map_out(fm_out[f]),
                .out_valid      (cv_valid[f])
            );
        end
    endgenerate

    // ── N_FILTERS ReLU instances (combinational) ──────────────────────────────
    wire [7:0] relu_out [0:N_FILTERS-1];

    generate
        for (f = 0; f < N_FILTERS; f = f + 1) begin : RELU_F
            relu rl_inst (
                .in (fm_out[f]),
                .out(relu_out[f])
            );
        end
    endgenerate

    // ── N_FILTERS 2×2 max-pool instances ─────────────────────────────────────
    // All share cv_valid[0] as data_valid (all filters fire together).
    wire [7:0] pool_out   [0:N_FILTERS-1];
    wire       pool_vld_f [0:N_FILTERS-1];

    generate
        for (f = 0; f < N_FILTERS; f = f + 1) begin : POOL_F
            max_pool mp_inst (
                .clk           (clk),
                .rst_n         (rst_n),
                .feature_map_in(relu_out[f]),
                .data_valid    (cv_valid[0]),   // shared; all identical
                .pooled_out    (pool_out[f]),
                .out_valid     (pool_vld_f[f])
            );
        end
    endgenerate

    // ── Register packed output ────────────────────────────────────────────────
    // pool_vld_f[0] is representative — all fire simultaneously.
    integer i;
    always @(posedge clk) begin
        if (!rst_n) begin
            pool_data  <= {N_FILTERS*8{1'b0}};
            pool_valid <= 1'b0;
        end else begin
            pool_valid <= pool_vld_f[0];
            if (pool_vld_f[0]) begin
                // Pack N_FILTERS 8-bit values into the output bus
                for (i = 0; i < N_FILTERS; i = i + 1)
                    pool_data[i*8 +: 8] <= pool_out[i];
            end
        end
    end

endmodule
