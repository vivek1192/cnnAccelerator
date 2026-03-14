// global_avg_pool.v
// Global Average Pooling — N_FILTERS parallel accumulators, serial output.
//
// Operation:
//   Accumulates pool_valid samples across the full image frame.
//   When sample_cnt reaches TOTAL_OUTPUTS, divides each accumulator by
//   2^SHIFT_BITS and emits N_FILTERS 8-bit averages ONE PER CLOCK
//   (serial output, out_valid high for N_FILTERS consecutive cycles).
//   This serial output feeds directly into fc_layer's streaming input.
//
// Output sequence (after frame complete):
//   Cycle 0: out_data = avg[0],  out_valid = 1
//   Cycle 1: out_data = avg[1],  out_valid = 1
//   ...
//   Cycle N_FILTERS-1: out_data = avg[N_FILTERS-1], out_valid = 1
//   Cycle N_FILTERS:   out_valid = 0  (idle until next frame)
//
// Parameters:
//   N_FILTERS     — number of parallel feature maps.
//   TOTAL_OUTPUTS — pool_valid pulses per frame (≈ 62×62 = 3844 for 5 stages
//                   on a 2048×2048 input image).
//   SHIFT_BITS    — right-shift applied for division.  2^SHIFT_BITS ≈ TOTAL_OUTPUTS.
//   ACC_WIDTH     — accumulator bit width (28 supports up to 255 × 2^20 samples).

module global_avg_pool #(
    parameter N_FILTERS     = 64,
    parameter TOTAL_OUTPUTS = 3844,
    parameter SHIFT_BITS    = 12,
    parameter ACC_WIDTH     = 28
)(
    input  wire       clk,
    input  wire       rst_n,

    // Input: N_FILTERS packed 8-bit pool values + valid strobe
    input  wire [N_FILTERS*8-1:0] data_in,
    input  wire                   data_valid,

    // Serial output: one 8-bit average per clock, out_valid high for N_FILTERS cycles
    output reg  [7:0] out_data,
    output reg        out_valid
);

    // ── Accumulators ──────────────────────────────────────────────────────────
    reg [ACC_WIDTH-1:0] acc [0:N_FILTERS-1];

    // ── Averaged results (latched after frame done) ───────────────────────────
    reg [7:0] avg_latch [0:N_FILTERS-1];

    // ── Counters ──────────────────────────────────────────────────────────────
    reg [15:0] sample_cnt;   // counts pool_valid pulses per frame
    reg [7:0]  emit_cnt;     // counts serial output cycles (0..N_FILTERS-1)

    // ── States ────────────────────────────────────────────────────────────────
    localparam S_ACC  = 1'b0;   // accumulating
    localparam S_EMIT = 1'b1;   // serial emission

    reg state;

    integer f;

    always @(posedge clk) begin
        if (!rst_n) begin
            state      <= S_ACC;
            sample_cnt <= 16'd0;
            emit_cnt   <= 8'd0;
            out_data   <= 8'd0;
            out_valid  <= 1'b0;
            for (f = 0; f < N_FILTERS; f = f + 1) begin
                acc[f]       <= {ACC_WIDTH{1'b0}};
                avg_latch[f] <= 8'd0;
            end
        end else begin
            out_valid <= 1'b0;   // default

            case (state)
                // ── Accumulation phase ────────────────────────────────────
                S_ACC: begin
                    if (data_valid) begin
                        for (f = 0; f < N_FILTERS; f = f + 1)
                            acc[f] <= acc[f] + {{(ACC_WIDTH-8){1'b0}},
                                                data_in[f*8 +: 8]};

                        if (sample_cnt == TOTAL_OUTPUTS - 1) begin
                            // Frame done: compute and latch averages
                            for (f = 0; f < N_FILTERS; f = f + 1) begin
                                if (|acc[f][ACC_WIDTH-1:SHIFT_BITS+8])
                                    avg_latch[f] <= 8'd255;
                                else
                                    avg_latch[f] <= acc[f][SHIFT_BITS +: 8];
                            end
                            // Reset accumulators for next frame
                            for (f = 0; f < N_FILTERS; f = f + 1)
                                acc[f] <= {ACC_WIDTH{1'b0}};
                            sample_cnt <= 16'd0;
                            emit_cnt   <= 8'd0;
                            state      <= S_EMIT;
                        end else begin
                            sample_cnt <= sample_cnt + 16'd1;
                        end
                    end
                end

                // ── Serial emission phase ─────────────────────────────────
                // Emits avg_latch[0], [1], ..., [N_FILTERS-1] one per clock.
                S_EMIT: begin
                    out_data  <= avg_latch[emit_cnt];
                    out_valid <= 1'b1;

                    if (emit_cnt == N_FILTERS - 1) begin
                        emit_cnt <= 8'd0;
                        state    <= S_ACC;
                    end else begin
                        emit_cnt <= emit_cnt + 8'd1;
                    end
                end
            endcase
        end
    end

endmodule
