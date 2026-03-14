// booth_mult.v
// Booth radix-2 multiplier: signed 8-bit weight × unsigned 8-bit activation
// Output: signed 16-bit product
//
// Algorithm:
//   Standard Booth radix-2 treats the multiplier as signed. Since our multiplier
//   (activation) is unsigned, we apply Booth on the 8 bits treating them as signed,
//   then add a correction term: if b[7]=1, add (a_signed × 2^8) to compensate
//   for the difference between signed and unsigned interpretation of bit 7.
//
//   Proof: b_unsigned = b_signed + 256  when b[7]=1
//          a × b_unsigned = a × b_signed + (a × 256  iff b[7]=1)
//
// Partial product generation (Booth radix-2, unrolled):
//   For each bit i (0..7), examine {b[i], b[i-1]} with b[-1] = 0:
//     2'b01 (0→1 transition): add  +a_extended << i
//     2'b10 (1→0 transition): add  −a_extended << i
//     2'b00 or 2'b11:         add   0
//
// Module is purely combinational — no clock, no state.
// Vivado will infer DSP48E2 from this pattern; the RTL serves as the
// functional reference model for testbench verification.

module booth_mult (
    input  wire signed [7:0]  a,      // signed multiplicand  (weight, W4/W8)
    input  wire        [7:0]  b,      // unsigned multiplier   (activation, U8)
    output wire signed [15:0] product
);

    // -------------------------------------------------------------------------
    // 1. Append implicit bit b[-1] = 0 below the LSB of b
    // -------------------------------------------------------------------------
    wire [8:0] ext_b = {b, 1'b0};
    //   ext_b[0]   = 0      = b[-1]  (implicit)
    //   ext_b[8:1] = b[7:0] = b[0..7]

    // -------------------------------------------------------------------------
    // 2. Sign-extend a to 20 bits for safe shifting (pp[7] needs a << 7 = 16 bits;
    //    correction needs a << 8 = 17 bits; 20-bit headroom covers both)
    // -------------------------------------------------------------------------
    wire signed [19:0] a_ext = {{12{a[7]}}, a};

    // -------------------------------------------------------------------------
    // 3. Generate 8 partial products (Booth for signed interpretation of b)
    // -------------------------------------------------------------------------
    wire signed [19:0] pp [0:7];

    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : gen_pp
            // bsel[1] = b[i]   = current bit   (Q_i)
            // bsel[0] = b[i-1] = previous bit  (Q_{i-1}), which is ext_b[i]
            wire [1:0] bsel = {ext_b[i+1], ext_b[i]};  // {Q_i, Q_{i-1}}

            assign pp[i] = (bsel == 2'b01) ?  (a_ext <<< i) :   // 0→1: add
                           (bsel == 2'b10) ? -(a_ext <<< i) :   // 1→0: subtract
                           20'sd0;                               // 00/11: zero
        end
    endgenerate

    // -------------------------------------------------------------------------
    // 4. Sum partial products (gives a × b_signed)
    // -------------------------------------------------------------------------
    wire signed [19:0] booth_product;
    assign booth_product = pp[0] + pp[1] + pp[2] + pp[3]
                         + pp[4] + pp[5] + pp[6] + pp[7];

    // -------------------------------------------------------------------------
    // 5. Correction for unsigned multiplier
    //    If b[7]=1, booth_product = a × (b_signed) = a × (b_unsigned − 256)
    //    So add a × 256 to recover a × b_unsigned.
    // -------------------------------------------------------------------------
    wire signed [19:0] correction = b[7] ? (a_ext <<< 8) : 20'sd0;

    // -------------------------------------------------------------------------
    // 6. Final product (always fits in 16 bits: range [−128×255, 127×255])
    // -------------------------------------------------------------------------
    wire signed [19:0] full_sum = booth_product + correction;
    assign product = full_sum[15:0];

endmodule
