// tb/tb_booth_mult.v
// Exhaustive self-checking testbench for booth_mult.
//
// Covers all 256 × 256 = 65 536 input combinations:
//   a ∈ [-128, 127]  (signed 8-bit weight)
//   b ∈ [0,   255]   (unsigned 8-bit activation)
//
// Expected result: a_signed × b_unsigned (signed 16-bit)
// Computed using Verilog's native $signed() arithmetic as the golden reference.
//
// Pass criteria: product == golden for every single combination.
// Final report prints PASS count, FAIL count, and first 5 failures if any.

`timescale 1ns/1ps

module tb_booth_mult;

    // -------------------------------------------------------------------------
    // DUT ports
    // -------------------------------------------------------------------------
    reg  signed [7:0]  a;
    reg         [7:0]  b;
    wire signed [15:0] product;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    booth_mult dut (
        .a      (a),
        .b      (b),
        .product(product)
    );

    // -------------------------------------------------------------------------
    // Test variables
    // -------------------------------------------------------------------------
    integer a_i, b_i;
    integer pass_cnt, fail_cnt;
    integer first_fails;
    reg signed [15:0] expected;

    // -------------------------------------------------------------------------
    // Exhaustive sweep
    // -------------------------------------------------------------------------
    initial begin
        $display("=====================================================");
        $display("tb_booth_mult: exhaustive 256x256 test (65536 cases)");
        $display("=====================================================");

        pass_cnt   = 0;
        fail_cnt   = 0;
        first_fails = 0;

        // a_i iterates over all signed 8-bit values: -128 .. 127
        for (a_i = -128; a_i <= 127; a_i = a_i + 1) begin
            for (b_i = 0; b_i <= 255; b_i = b_i + 1) begin

                a = a_i[7:0];   // truncate to 8 bits (handles -128 correctly)
                b = b_i[7:0];
                #1;             // settle combinational logic

                // Golden reference: signed × unsigned = signed 16-bit
                // $signed(a) × b_i: a is already signed; b_i is an integer
                // product range: [-128×255, 127×255] = [-32640, 32385] → fits 16 bits
                expected = $signed(a) * $signed({1'b0, b}); // zero-extend b for multiply

                if (product === expected) begin
                    pass_cnt = pass_cnt + 1;
                end else begin
                    fail_cnt = fail_cnt + 1;
                    if (first_fails < 5) begin
                        $display("FAIL a=%0d b=%0d : got %0d, expected %0d",
                                 $signed(a), b, $signed(product), $signed(expected));
                        first_fails = first_fails + 1;
                    end
                end
            end
        end

        // ---- Summary --------------------------------------------------------
        $display("-----------------------------------------------------");
        $display("Results: %0d PASS  /  %0d FAIL  (total %0d)",
                 pass_cnt, fail_cnt, pass_cnt + fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("=====================================================");
        $finish;
    end

endmodule