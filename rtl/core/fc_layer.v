// fc_layer.v
// Parameterizable fully-connected layer with time-multiplexed MAC.
//
// Architecture:
//   Phase 1 (S_FILL):    Collects N_IN 8-bit unsigned inputs into an input
//                        buffer, using the data_valid handshake.
//   Phase 2 (S_COMPUTE): For each neuron (0..N_OUT-1), accumulate N_IN MACs:
//                          acc += w_rom[neuron * N_IN + i] × in_buf[i]
//                        One MAC per clock cycle → N_IN cycles per neuron.
//   Phase 3 (S_BIAS):    Apply bias, ReLU, saturate to [0,255], emit output.
//                        One cycle per neuron; then moves to next neuron or
//                        returns to S_FILL when all neurons are done.
//
// Latency per inference (cycles):
//   Fill:    N_IN
//   Compute: N_OUT × (N_IN + 1)   (+1 for the S_BIAS cycle per neuron)
//   Total:   N_IN + N_OUT × (N_IN + 1)
//   Example: N_IN=49, N_OUT=8  →  49 + 8×50 = 449 cycles = 4.49 µs @ 100 MHz
//
// Weight ROM (w_rom):
//   (* rom_style = "distributed" *) — async LUT-based ROM, no BRAM latency.
//   Loaded via $readmemh from WEIGHT_FILE.
//   Layout: row-major, neuron-major.
//     Index [neuron * N_IN + input] = w[neuron][input]
//   File format: one 8-bit hex value per line (e.g. "01", "FE").
//
// Bias ROM (b_rom):
//   Loaded via $readmemh from BIAS_FILE.
//   One 16-bit signed value per neuron.
//   File format: one 16-bit hex value per line (e.g. "FF38" = -200).
//
// Output:
//   data_out[7:0] — 8-bit unsigned, ReLU-clamped neuron activation.
//   out_valid     — asserted for 1 cycle per output neuron.
//   busy          — high while in COMPUTE or BIAS phase.
//
// Note: The upstream must NOT send a new image while busy=1.
//   For a single-image pipeline, wait for busy to go low after all
//   N_OUT outputs have been emitted before sending the next frame.

module fc_layer #(
    parameter N_IN        = 49,
    parameter N_OUT       = 8,
    parameter WEIGHT_FILE = "syn/weights/fc1_weights.mem",
    parameter BIAS_FILE   = "syn/weights/fc1_biases.mem"
)(
    input  wire       clk,
    input  wire       rst_n,

    // Upstream: streaming 8-bit inputs with valid handshake
    input  wire [7:0] data_in,
    input  wire       data_valid,

    // Downstream: N_OUT sequential 8-bit outputs
    output reg  [7:0] data_out,
    output reg        out_valid,

    // Status: high while computing (S_COMPUTE or S_BIAS)
    output reg        busy
);

    // ── Weight & Bias ROMs ────────────────────────────────────────────────────
    // Distributed ROM → combinational (async) read, no pipeline stage needed.
    localparam ROM_DEPTH = N_OUT * N_IN;

    (* rom_style = "distributed" *)
    reg signed [7:0]  w_rom [0:ROM_DEPTH-1];
    reg signed [15:0] b_rom [0:N_OUT-1];

    initial begin
        if (WEIGHT_FILE != "") $readmemh(WEIGHT_FILE, w_rom);
        if (BIAS_FILE   != "") $readmemh(BIAS_FILE,   b_rom);
    end

    // ── Input buffer ──────────────────────────────────────────────────────────
    // Stores one complete set of N_IN activations from the previous layer.
    reg [7:0] in_buf [0:N_IN-1];

    // ── State machine ─────────────────────────────────────────────────────────
    localparam S_FILL    = 2'd0;   // collecting N_IN inputs
    localparam S_COMPUTE = 2'd1;   // MAC loop
    localparam S_BIAS    = 2'd2;   // bias + ReLU + emit

    reg [1:0] state;

    // ── Counters (8-bit supports up to N_IN/N_OUT = 255) ─────────────────────
    reg [7:0] in_cnt;    // input fill counter: 0 .. N_IN-1
    reg [7:0] neu_idx;   // current neuron:     0 .. N_OUT-1
    reg [7:0] mac_cnt;   // MAC step:           0 .. N_IN-1

    // ── MAC accumulator ───────────────────────────────────────────────────────
    // Max magnitude: N_IN × 127 × 255 = 49 × 32,385 = 1,586,865  (< 2^21)
    // 24-bit signed covers up to ±8,388,607 — safe for N_IN ≤ 255.
    reg signed [23:0] acc;

    // ── Bias application (combinational) ─────────────────────────────────────
    // Evaluated in S_BIAS where acc holds the full neuron sum.
    // Sign-extend acc (24-bit) and bias (16-bit) to 25 bits for safe addition.
    wire signed [24:0] biased_w =
        {{1{acc[23]}},      acc      } +
        {{9{b_rom[neu_idx][15]}}, b_rom[neu_idx]};

    // ── ROM address (combinational) ───────────────────────────────────────────
    wire [11:0] w_addr = neu_idx * N_IN + mac_cnt;   // 12-bit: max 255*255+254=65,279

    always @(posedge clk) begin
        if (!rst_n) begin
            state     <= S_FILL;
            in_cnt    <= 8'd0;
            neu_idx   <= 8'd0;
            mac_cnt   <= 8'd0;
            acc       <= 24'sd0;
            data_out  <= 8'd0;
            out_valid <= 1'b0;
            busy      <= 1'b0;
        end else begin
            out_valid <= 1'b0;   // default: de-assert every cycle

            case (state)

                // ── Phase 1: buffer N_IN upstream activations ─────────────
                S_FILL: begin
                    busy <= 1'b0;
                    if (data_valid) begin
                        in_buf[in_cnt] <= data_in;
                        if (in_cnt == N_IN - 1) begin
                            in_cnt  <= 8'd0;
                            neu_idx <= 8'd0;
                            mac_cnt <= 8'd0;
                            acc     <= 24'sd0;
                            state   <= S_COMPUTE;
                            busy    <= 1'b1;
                        end else begin
                            in_cnt <= in_cnt + 8'd1;
                        end
                    end
                end

                // ── Phase 2: accumulate one MAC per cycle ──────────────────
                // w_rom is async → combinational read at w_addr.
                // acc is non-blocking → holds sum of products 0..mac_cnt-1
                // at the start of each cycle.
                S_COMPUTE: begin
                    (* use_dsp = "yes" *)
                    acc <= acc + $signed(w_rom[w_addr])
                               * $signed({1'b0, in_buf[mac_cnt]});

                    if (mac_cnt == N_IN - 1) begin
                        // Last MAC fired (lands in acc next cycle via NB)
                        state <= S_BIAS;
                    end else begin
                        mac_cnt <= mac_cnt + 8'd1;
                    end
                end

                // ── Phase 3: bias + ReLU + saturate + emit ────────────────
                // At entry, acc contains the full N_IN-product sum.
                // biased_w = acc + bias  (25-bit, combinational).
                S_BIAS: begin
                    // ReLU: negative → 0
                    // Saturate: > 255 → 255
                    if (biased_w[24]) begin             // negative
                        data_out <= 8'd0;
                    end else if (|biased_w[24:8]) begin // > 255
                        data_out <= 8'd255;
                    end else begin
                        data_out <= biased_w[7:0];
                    end
                    out_valid <= 1'b1;

                    if (neu_idx == N_OUT - 1) begin
                        // All neurons done — ready for next image
                        state <= S_FILL;
                        busy  <= 1'b0;
                    end else begin
                        // Advance to next neuron
                        neu_idx <= neu_idx + 8'd1;
                        mac_cnt <= 8'd0;
                        acc     <= 24'sd0;
                        state   <= S_COMPUTE;
                    end
                end

                default: state <= S_FILL;
            endcase
        end
    end

endmodule
