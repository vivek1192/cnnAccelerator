// simple_cnn.v
// Top-level simple CNN pipeline:
//   conv_layer (3×3) → relu → max_pool (2×2)
//
// Hardcoded weights: vertical-edge Sobel kernel
//   -1  0 +1
//   -1  0 +1
//   -1  0 +1
// (represented as signed 8-bit: -1 = 8'hFF, 0 = 8'h00, +1 = 8'h01)
//
// Streaming interface: one 8-bit pixel per clock cycle (pixel_valid handshake).
// Output: one 8-bit pooled value every 4 conv outputs (2×2 max pool).

module simple_cnn (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] pixel_in,
    input  wire       pixel_valid,
    output wire [7:0] pooled_out,
    output wire       pool_valid
);

    // -------------------------------------------------------------------------
    // Hardcoded weights: vertical-edge Sobel, row-major, 9×8-bit signed
    // Layout: w[0..2]=row0, w[3..5]=row1, w[6..8]=row2
    //   w[0]=-1  w[1]=0  w[2]=+1
    //   w[3]=-1  w[4]=0  w[5]=+1
    //   w[6]=-1  w[7]=0  w[8]=+1
    // Packed: weights[7:0]=w[0], weights[15:8]=w[1], ..., weights[71:64]=w[8]
    // -------------------------------------------------------------------------
    wire [71:0] weights = {
        8'sh01,   // w[8] = +1  (bottom-right)
        8'sh00,   // w[7] =  0
        8'shFF,   // w[6] = -1  (bottom-left)
        8'sh01,   // w[5] = +1
        8'sh00,   // w[4] =  0
        8'shFF,   // w[3] = -1
        8'sh01,   // w[2] = +1  (top-right)
        8'sh00,   // w[1] =  0
        8'shFF    // w[0] = -1  (top-left)
    };

    // -------------------------------------------------------------------------
    // Stage 1: 3×3 convolution (streaming, 1 pixel/cycle)
    // -------------------------------------------------------------------------
    wire [15:0] feature_map;
    wire        conv_valid;

    conv_layer #(
        .IMAGE_WIDTH (8),
        .FILTER_SIZE (3)
    ) conv_inst (
        .clk            (clk),
        .rst_n          (rst_n),
        .pixel_in       (pixel_in),
        .pixel_valid    (pixel_valid),
        .weights        (weights),
        .feature_map_out(feature_map),
        .out_valid      (conv_valid)
    );

    // -------------------------------------------------------------------------
    // Stage 2: ReLU (combinational, zero-latency)
    // -------------------------------------------------------------------------
    wire [7:0] relu_out;

    relu relu_inst (
        .in (feature_map),
        .out(relu_out)
    );

    // ReLU valid follows conv_valid (combinational, no extra latency)
    wire relu_valid = conv_valid;

    // -------------------------------------------------------------------------
    // Stage 3: 2×2 max pooling (registered, 1-cycle output latency per window)
    // -------------------------------------------------------------------------
    max_pool maxpool_inst (
        .clk           (clk),
        .rst_n         (rst_n),
        .feature_map_in(relu_out),
        .data_valid    (relu_valid),
        .pooled_out    (pooled_out),
        .out_valid     (pool_valid)
    );

endmodule
