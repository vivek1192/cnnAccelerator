// relu.v
module relu (
    input wire [15:0] in,
    output reg [7:0] out
);

// ReLU: clamp negative values to 0, positive values to [0, 255].
// Bug fix: original used "in > 8'b0" which is an unsigned comparison —
// a negative 16-bit signed value (e.g. 0x8000) would compare as > 0.
// Correct approach: check sign bit in[15] directly.
always @(in) begin
    if (in[15])                            // MSB=1 → negative signed value
        out = 8'd0;
    else if (|in[15:8])                    // any high byte bit set → > 255
        out = 8'd255;                      // saturate to max unsigned 8-bit
    else
        out = in[7:0];                     // fits in 8 bits, pass through
end

endmodule