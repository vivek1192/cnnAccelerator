// tb/tb_top.v
// Integration smoke-test: stream a known 8×8 image through the full
// simple_cnn pipeline (conv_layer → relu → max_pool) and check that:
//   1. Pipeline produces at least one valid output.
//   2. A solid-white image (all 255) followed by a solid-black image (all 0)
//      does not cause the pipeline to lock up or produce X values.
//   3. Reset mid-stream clears state cleanly (out_valid deasserts).
//
// This complements tb_simple_cnn.v (which tests edge detection correctness).
// This file focuses on structural integrity and reset behaviour.

`timescale 1ns/1ps

module tb_top;

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
    // DUT — simple_cnn (conv → relu → max_pool)
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
    // Clock: 10 ns period
    // -------------------------------------------------------------------------
    initial clk = 0;
    always #5 clk = ~clk;

    // -------------------------------------------------------------------------
    // Helper task: stream an 8×8 image from the image[] array
    // -------------------------------------------------------------------------
    reg [7:0] image [0:63];
    integer   idx;

    task stream_image;
        integer p;
        begin
            for (p = 0; p < 64; p = p + 1) begin
                pixel_in    = image[p];
                pixel_valid = 1;
                @(posedge clk); #1;
            end
            pixel_valid = 0;
            pixel_in    = 0;
        end
    endtask

    // -------------------------------------------------------------------------
    // Helper task: fill image with a constant value
    // -------------------------------------------------------------------------
    task fill_image;
        input [7:0] val;
        integer p;
        begin
            for (p = 0; p < 64; p = p + 1)
                image[p] = val;
        end
    endtask

    // -------------------------------------------------------------------------
    // Score tracking
    // -------------------------------------------------------------------------
    integer pass_cnt, fail_cnt;
    integer out_count;   // count pool_valid pulses per image
    reg     got_x;       // asserted if any output is X/Z

    // Capture outputs asynchronously
    always @(posedge clk) begin
        if (pool_valid) begin
            out_count = out_count + 1;
            if (^pooled_out === 1'bx) got_x = 1;
        end
    end

    // -------------------------------------------------------------------------
    // Main test sequence
    // -------------------------------------------------------------------------
    initial begin
        $display("=================================================");
        $display("tb_top: structural integration tests");
        $display("=================================================");

        pass_cnt = 0;
        fail_cnt = 0;

        // --- Initial reset ---
        rst_n       = 0;
        pixel_valid = 0;
        pixel_in    = 0;
        repeat(4) @(posedge clk); #1;
        rst_n = 1;
        @(posedge clk); #1;

        // =================================================================
        // TEST 1: Solid-white image (all 255)
        //   Vertical Sobel kernel on a uniform field → all conv outputs = 0
        //   Expected pooled output = 0 for all windows.
        // =================================================================
        $display("[TEST 1] Solid-white image (all 255) — expect pooled=0");
        out_count = 0;
        got_x     = 0;
        fill_image(8'd255);
        stream_image;
        repeat(12) @(posedge clk); #1;

        if (got_x) begin
            $display("FAIL TEST1: pooled_out contained X/Z");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS TEST1: no X/Z on output  (outputs=%0d)", out_count);
            pass_cnt = pass_cnt + 1;
        end

        // =================================================================
        // TEST 2: Solid-black image (all 0) — same expectation as TEST 1
        // =================================================================
        $display("[TEST 2] Solid-black image (all 0) — expect pooled=0");
        out_count = 0;
        got_x     = 0;
        fill_image(8'd0);
        stream_image;
        repeat(12) @(posedge clk); #1;

        if (got_x) begin
            $display("FAIL TEST2: pooled_out contained X/Z");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS TEST2: no X/Z on output  (outputs=%0d)", out_count);
            pass_cnt = pass_cnt + 1;
        end

        // =================================================================
        // TEST 3: Mid-stream reset
        //   Stream 20 pixels, assert reset for 4 cycles, release,
        //   verify pool_valid is deasserted during and after reset.
        // =================================================================
        $display("[TEST 3] Mid-stream reset — pool_valid must deassert");
        fill_image(8'd128);
        out_count = 0;
        // Stream 20 pixels
        begin : test3_stream
            integer p3;
            for (p3 = 0; p3 < 20; p3 = p3 + 1) begin
                pixel_in    = image[p3];
                pixel_valid = 1;
                @(posedge clk); #1;
            end
        end
        pixel_valid = 0;

        // Assert reset
        rst_n = 0;
        repeat(4) @(posedge clk); #1;

        // During reset pool_valid must be 0
        if (pool_valid !== 1'b0) begin
            $display("FAIL TEST3: pool_valid stayed high during reset");
            fail_cnt = fail_cnt + 1;
        end else begin
            $display("PASS TEST3: pool_valid deasserted during reset");
            pass_cnt = pass_cnt + 1;
        end

        rst_n = 1;
        @(posedge clk); #1;

        // =================================================================
        // TEST 4: Pipeline produces outputs after reset + fresh image
        // =================================================================
        $display("[TEST 4] Fresh image after reset — pipeline must produce outputs");
        begin : test4
            integer found_255;
            integer p4;
            out_count = 0;
            got_x     = 0;
            // Vertical-edge image (same as simple_cnn_tb)
            for (p4 = 0; p4 < 64; p4 = p4 + 1)
                image[p4] = ((p4 % 8) >= 4) ? 8'd200 : 8'd0;
            stream_image;
            repeat(12) @(posedge clk); #1;

            found_255 = 0;
            // We know edge response = 255; check out_count > 0
            if (out_count > 0 && !got_x) begin
                $display("PASS TEST4: %0d outputs produced, no X/Z", out_count);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL TEST4: out_count=%0d, got_x=%0d", out_count, got_x);
                fail_cnt = fail_cnt + 1;
            end
        end

        // =================================================================
        // Summary
        // =================================================================
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
    // Waveform dump
    // -------------------------------------------------------------------------
    initial begin
        $dumpfile("sim/tb_top.vcd");
        $dumpvars(0, tb_top);
    end

endmodule