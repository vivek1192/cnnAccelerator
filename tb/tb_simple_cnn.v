// simple_cnn_tb.v
// Self-checking testbench for simple_cnn.
//
// Test image (8×8, unsigned 8-bit, streamed row-major):
//   Columns 0-3 = 0, Columns 4-7 = 200
//   This creates a sharp vertical edge between columns 3 and 4.
//
//   Row:  col0 col1 col2 col3 | col4 col5 col6 col7
//     0:    0    0    0    0  | 200  200  200  200
//     ...
//     7:    0    0    0    0  | 200  200  200  200
//
// Kernel (vertical Sobel, hardcoded in simple_cnn.v):
//   -1  0 +1
//   -1  0 +1
//   -1  0 +1
//
// Expected conv output at output column 2 (input cols 2-4):
//   sum = 3 × (+1 × 200) = 600 → relu clamps to 255
// Expected conv output at output column 3 (input cols 3-5):
//   sum = 3 × (-1×0 + 0×200 + 1×200) = 600 → relu clamps to 255
// Expected conv output at output column 0 (input cols 0-2):
//   sum = 3 × (-1×0 + 0×0 + 1×0) = 0 → relu = 0
//
// After 2×2 max pooling, any region containing a 255 should pool to 255.

`timescale 1ns/1ps

module simple_cnn_tb;

    // -------------------------------------------------------------------------
    // DUT signals
    // -------------------------------------------------------------------------
    reg        clk;
    reg        rst_n;
    reg  [7:0] pixel_in;
    reg        pixel_valid;
    wire [7:0] pooled_out;
    wire       pool_valid;

    // -------------------------------------------------------------------------
    // DUT instantiation
    // -------------------------------------------------------------------------
    simple_cnn dut (
        .clk        (clk),
        .rst_n      (rst_n),
        .pixel_in   (pixel_in),
        .pixel_valid(pixel_valid),
        .pooled_out (pooled_out),
        .pool_valid (pool_valid)
    );

    // -------------------------------------------------------------------------
    // Clock: 10 ns period (100 MHz)
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Test image: 8×8, vertical edge at column 4
    // -------------------------------------------------------------------------
    reg [7:0] image [0:63];
    integer   r, c, idx;

    initial begin
        for (r = 0; r < 8; r = r + 1)
            for (c = 0; c < 8; c = c + 1)
                image[r*8 + c] = (c >= 4) ? 8'd200 : 8'd0;
    end

    // -------------------------------------------------------------------------
    // Score tracking
    // -------------------------------------------------------------------------
    integer pass_cnt;
    integer fail_cnt;
    integer pool_out_idx;
    reg [7:0] pool_results [0:8];  // collect up to 9 pooled outputs

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================");
        $display("simple_cnn_tb: vertical edge detection test");
        $display("=================================================");

        pass_cnt     = 0;
        fail_cnt     = 0;
        pool_out_idx = 0;

        // Reset
        rst_n       = 0;
        pixel_valid = 0;
        pixel_in    = 0;
        repeat(4) @(posedge clk);
        #1;
        rst_n = 1;
        @(posedge clk); #1;

        // Stream 64 pixels (8×8 image), one per clock
        $display("[TB] Streaming 8x8 image...");
        for (idx = 0; idx < 64; idx = idx + 1) begin
            pixel_in    = image[idx];
            pixel_valid = 1;
            @(posedge clk); #1;
        end
        pixel_valid = 0;
        pixel_in    = 0;

        // Wait for pipeline to drain
        repeat(12) @(posedge clk);

        // ----------------------------------------------------------------
        // Report
        // ----------------------------------------------------------------
        $display("\n[TB] Pooled outputs collected: %0d", pool_out_idx);
        for (idx = 0; idx < pool_out_idx; idx = idx + 1)
            $display("  pool_result[%0d] = %0d", idx, pool_results[idx]);

        // CHECK 1: at least one pooled output must be 255 (edge region)
        begin : check_edge
            integer found_edge;
            found_edge = 0;
            for (idx = 0; idx < pool_out_idx; idx = idx + 1)
                if (pool_results[idx] == 8'd255) found_edge = 1;
            if (found_edge) begin
                $display("PASS: edge response (255) found in pooled output.");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: no edge response in pooled output.");
                fail_cnt = fail_cnt + 1;
            end
        end

        // CHECK 2: pool_results[1] must be 0 (the flat post-edge window).
        // pool[0] = max(col0,col1,col2,col3) = max(0,0,255,255) = 255  ← edge included
        // pool[1] = max(col4,col5,row3_col0,row3_col1) = max(0,0,0,0) = 0  ← flat region
        if (pool_out_idx > 1) begin
            if (pool_results[1] == 8'd0) begin
                $display("PASS: pool_results[1] = 0 (post-edge flat region correct).");
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL: pool_results[1] = %0d (expected 0).", pool_results[1]);
                fail_cnt = fail_cnt + 1;
            end
        end

        // Summary
        $display("\n=================================================");
        $display("SUMMARY: %0d PASS, %0d FAIL", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");
        $display("=================================================");
        $finish;
    end

    // -------------------------------------------------------------------------
    // Capture pooled outputs
    // -------------------------------------------------------------------------
    always @(posedge clk) begin
        if (pool_valid && pool_out_idx < 9) begin
            pool_results[pool_out_idx] = pooled_out;
            pool_out_idx               = pool_out_idx + 1;
            $display("[TB] pool[%0d] = %0d", pool_out_idx - 1, pooled_out);
        end
    end

    // -------------------------------------------------------------------------
    // Waveform dump (for GTKWave)
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("sim/simple_cnn.vcd");
        $dumpvars(0, simple_cnn_tb);
    end

endmodule
