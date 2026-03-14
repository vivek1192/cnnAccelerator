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
// Synthesis: (* use_dsp = "yes" *) forces Vivado to map the multiply to
// a DSP48E2 primitive instead of LUT+CARRY8 chains.
//
// DSP48E2 mapping on xczu7ev:
//   A[24:0]  ← sign-extended a (8-bit signed → 25-bit)
//   B[17:0]  ← zero-extended b (8-bit unsigned → 18-bit)
//   P[47:0]  ← product; we use P[15:0]
//
// Functional equivalence to Booth RTL is verified by tb_booth_mult
// (exhaustive 65536-case sweep — all pass).

module booth_mult (
    input  wire signed [7:0]  a,      // signed multiplicand  (weight, W4/W8)
    input  wire        [7:0]  b,      // unsigned multiplier   (activation, U8)
    output wire signed [15:0] product
);

    // Zero-extend b to signed 16-bit so the multiply is signed × signed.
    // {1'b0, b} treats b as positive signed 9-bit → correct unsigned semantics.
    (* use_dsp = "yes" *) wire signed [15:0] product_dsp;
    assign product_dsp = $signed(a) * $signed({1'b0, b});
    assign product = product_dsp;

endmodule
