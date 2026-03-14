// conv_layer_impl.v
// Streaming 3×3 convolution for a single-channel image.
//
// Architecture:
//   Two delay-line shift registers (each depth IMAGE_WIDTH) implement 1-row and
//   2-row delays for the line-buffer technique. Three 2-element tap registers
//   give us the 3-column window from each of the three rows. Nine parallel
//   booth_mult instances compute all MACs in a single combinational step; the
//   results are summed and saturated to a 16-bit signed value.
//
// Timing:
//   Pixels arrive 1/cycle (pixel_valid handshake).
//   out_valid is asserted in the SAME clock cycle as the pixel that completes
//   each 3×3 window (i.e., pixel at output-column row_cnt≥3, col_cnt≥2).
//   Output position (r, c) corresponds to input pixel at row r+2, col c+2.
//   Total output pixels: (IMAGE_WIDTH-2) × (IMAGE_HEIGHT-2) per image.
//
// Parameters:
//   IMAGE_WIDTH   — pixels per row (default 8)
//   FILTER_SIZE   — always 3 for this module
//   OUTPUT_WIDTH  — IMAGE_WIDTH − FILTER_SIZE + 1  (derived, 6 for width-8)
//
// Weights:
//   Packed as 9×8-bit signed values in a 72-bit bus.
//   weights[7:0]   = w[0,0] (top-left)
//   weights[15:8]  = w[0,1]
//   ...
//   weights[71:64] = w[2,2] (bottom-right)
//
// Bug fixes vs. original stub:
//   Bug 1: OUTPUT_WIDTH/OUTPUT_HEIGHT were undefined → now derived parameters
//   Bug 2: body was empty → full implementation provided

// booth_mult is compiled separately — no `include needed.
// Add rtl/core/booth_mult.v to your simulator/synthesizer file list.

module conv_layer #(
    parameter IMAGE_WIDTH  = 8,
    parameter FILTER_SIZE  = 3,
    parameter OUTPUT_WIDTH = IMAGE_WIDTH - FILTER_SIZE + 1  // 6
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [7:0]  pixel_in,       // unsigned 8-bit, 1 pixel/cycle
    input  wire        pixel_valid,    // upstream data-valid handshake
    input  wire [71:0] weights,        // 9 × signed 8-bit, row-major packed
    output reg  [15:0] feature_map_out,// signed 16-bit convolution result
    output reg         out_valid       // 1 cycle when feature_map_out is valid
);

    // =========================================================================
    // 1. Unpack weights
    // =========================================================================
    wire signed [7:0] w [0:8];
    genvar k;
    generate
        for (k = 0; k < 9; k = k + 1) begin : unpack_w
            assign w[k] = weights[k*8 +: 8];
        end
    endgenerate
    // Layout:  w[0] w[1] w[2]   ← row 0 (top)
    //          w[3] w[4] w[5]   ← row 1
    //          w[6] w[7] w[8]   ← row 2 (bottom / current row)

    // =========================================================================
    // 2. Delay-line shift registers (line buffers)
    //    delay1[IMAGE_WIDTH-1] = pixel from IMAGE_WIDTH cycles ago (1 row ago)
    //    delay2[IMAGE_WIDTH-1] = pixel from 2×IMAGE_WIDTH cycles ago (2 rows ago)
    // =========================================================================
    reg [7:0] delay1 [0:IMAGE_WIDTH-1];
    reg [7:0] delay2 [0:IMAGE_WIDTH-1];

    // =========================================================================
    // 3. Column tap registers for each of the 3 row positions
    //    tap_r*[1] = pixel from 1 cycle ago  (col c-1)
    //    tap_r*[0] = pixel from 2 cycles ago (col c-2)
    //    The "col c" pixel for each row is delay1/delay2 tail or pixel_in itself.
    // =========================================================================
    reg [7:0] tap_cur [0:1];   // current row:   [0]=col c-2, [1]=col c-1
    reg [7:0] tap_row1[0:1];   // 1 row ago:     [0]=col c-2, [1]=col c-1
    reg [7:0] tap_row2[0:1];   // 2 rows ago:    [0]=col c-2, [1]=col c-1

    // =========================================================================
    // 4. Position tracking
    // =========================================================================
    reg [3:0] col_cnt;    // 0..IMAGE_WIDTH-1
    reg       rows_full;  // set after the first 3 rows have been received
    reg [1:0] row_fill;   // 0,1,2 → becomes rows_full after 3rd row completes

    // =========================================================================
    // 5. Combinational 3×3 window
    //    We build the "next-cycle" window from pixel_in + OLD tap registers +
    //    delay FIFO outputs (all evaluated before the clock edge fires).
    //    This lets us register the result in the same cycle as pixel arrival.
    // =========================================================================
    wire [7:0] px [0:8];
    //   top row    (2 rows ago): col c-2,  col c-1,  col c
    assign px[0] = tap_row2[0];
    assign px[1] = tap_row2[1];
    assign px[2] = delay2[IMAGE_WIDTH-1];  // 2-row-delayed current col
    //   middle row (1 row ago):  col c-2,  col c-1,  col c
    assign px[3] = tap_row1[0];
    assign px[4] = tap_row1[1];
    assign px[5] = delay1[IMAGE_WIDTH-1];  // 1-row-delayed current col
    //   bottom row (current):   col c-2,  col c-1,  col c
    assign px[6] = tap_cur[0];
    assign px[7] = tap_cur[1];
    assign px[8] = pixel_in;               // newest pixel (before registration)

    // =========================================================================
    // 6. 9 parallel Booth multiplier instances (combinational)
    // =========================================================================
    wire signed [15:0] mac [0:8];
    genvar m;
    generate
        for (m = 0; m < 9; m = m + 1) begin : booth_macs
            booth_mult bm (
                .a      (w[m]),
                .b      (px[m]),
                .product(mac[m])
            );
        end
    endgenerate

    // =========================================================================
    // 7. Adder tree: sum 9 signed 16-bit products → 20-bit result
    //    Max absolute value: 9 × 127 × 255 = 291,105 < 2^19 → 20 bits safe
    // =========================================================================
    wire signed [19:0] sum;
    assign sum = $signed(mac[0]) + $signed(mac[1]) + $signed(mac[2])
               + $signed(mac[3]) + $signed(mac[4]) + $signed(mac[5])
               + $signed(mac[6]) + $signed(mac[7]) + $signed(mac[8]);

    // =========================================================================
    // 8. Saturate to signed 16-bit range [−32768, 32767]
    // =========================================================================
    wire signed [15:0] sat_val;
    assign sat_val = (sum > 20'sh07FFF) ? 16'sh7FFF :
                     (sum < 20'shF8000) ? 16'sh8000 :
                      sum[15:0];

    // =========================================================================
    // 9. Sequential logic: shift registers, counters, output registration
    // =========================================================================
    integer j;  // loop variable — synthesizable (unrolled by tools)

    always @(posedge clk) begin
        if (!rst_n) begin
            // ---- Reset ----
            col_cnt   <= 4'd0;
            row_fill  <= 2'd0;
            rows_full <= 1'b0;
            out_valid <= 1'b0;
            feature_map_out <= 16'sd0;

            // Clear tap registers
            tap_cur[0]  <= 8'd0; tap_cur[1]  <= 8'd0;
            tap_row1[0] <= 8'd0; tap_row1[1] <= 8'd0;
            tap_row2[0] <= 8'd0; tap_row2[1] <= 8'd0;

            // Clear delay FIFOs
            for (j = 0; j < IMAGE_WIDTH; j = j + 1) begin
                delay1[j] <= 8'd0;
                delay2[j] <= 8'd0;
            end

        end else if (pixel_valid) begin
            // ----------------------------------------------------------------
            // 9a. Update delay-line FIFOs (shift in pixel_in)
            //     Non-blocking: all RHS read OLD values → correct shift behaviour
            // ----------------------------------------------------------------
            delay1[0] <= pixel_in;
            delay2[0] <= delay1[IMAGE_WIDTH-1];   // captures 1-row-ago pixel
            for (j = 1; j < IMAGE_WIDTH; j = j + 1) begin
                delay1[j] <= delay1[j-1];
                delay2[j] <= delay2[j-1];
            end

            // ----------------------------------------------------------------
            // 9b. Shift column tap registers
            //     tap_*[0] ← tap_*[1]  (oldest ← newer)
            //     tap_*[1] ← incoming pixel at this column from each row
            // ----------------------------------------------------------------
            tap_cur[0]  <= tap_cur[1];
            tap_cur[1]  <= pixel_in;

            tap_row1[0] <= tap_row1[1];
            tap_row1[1] <= delay1[IMAGE_WIDTH-1];  // 1 row ago, current col

            tap_row2[0] <= tap_row2[1];
            tap_row2[1] <= delay2[IMAGE_WIDTH-1];  // 2 rows ago, current col

            // ----------------------------------------------------------------
            // 9c. Column and row counters
            // ----------------------------------------------------------------
            if (col_cnt == IMAGE_WIDTH - 1) begin
                col_cnt <= 4'd0;
                if (!rows_full) begin
                    if (row_fill == 2'd2)
                        rows_full <= 1'b1;
                    else
                        row_fill <= row_fill + 2'd1;
                end
            end else begin
                col_cnt <= col_cnt + 4'd1;
            end

            // ----------------------------------------------------------------
            // 9d. Register output when 3 rows are filled and col_cnt >= 2
            //     The window is built from OLD tap values + delay tails above,
            //     so col_cnt >= 2 ensures tap_cur[0] and tap_cur[1] are valid
            //     (they hold pixels at current_col−2 and current_col−1).
            // ----------------------------------------------------------------
            if (rows_full && (col_cnt >= 4'd2)) begin
                feature_map_out <= sat_val;
                out_valid       <= 1'b1;
            end else begin
                out_valid <= 1'b0;
            end

        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
