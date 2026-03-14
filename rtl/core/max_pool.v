// max_pool.v
// 2×2 max pooling on a stream of 8-bit unsigned values.
// Consumes 4 consecutive valid input pixels per output pixel.
//
// Bug fixes vs. original:
//   Bug 1: `integer i` (not synthesizable as state) → replaced with reg [1:0] count_r
//   Bug 2: blocking `i = i + 1` inside clocked always → all non-blocking (<=)
//   Bug 3: `i` never initialized in reset → count_r <= 2'd0 in reset branch
//
// Interface:
//   data_valid  — upstream asserts when feature_map_in is valid
//   out_valid   — asserted for 1 cycle when pooled_out holds a new max value

module max_pool (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [7:0] feature_map_in,
    input  wire       data_valid,
    output reg  [7:0] pooled_out,
    output reg        out_valid
);

    parameter POOL_SIZE = 2;  // 2×2 window → 4 samples per output

    reg [7:0] max_val;
    reg [1:0] count_r;  // counts 0..3 (POOL_SIZE² − 1)

    always @(posedge clk) begin
        if (!rst_n) begin
            pooled_out <= 8'd0;
            out_valid  <= 1'b0;
            max_val    <= 8'd0;
            count_r    <= 2'd0;
        end else if (data_valid) begin
            // Track the running maximum
            if (feature_map_in > max_val)
                max_val <= feature_map_in;

            if (count_r == 2'd3) begin
                // Window complete — emit output
                pooled_out <= (feature_map_in > max_val) ? feature_map_in : max_val;
                out_valid  <= 1'b1;
                max_val    <= 8'd0;
                count_r    <= 2'd0;
            end else begin
                out_valid <= 1'b0;
                count_r   <= count_r + 2'd1;
            end
        end else begin
            out_valid <= 1'b0;
        end
    end

endmodule
