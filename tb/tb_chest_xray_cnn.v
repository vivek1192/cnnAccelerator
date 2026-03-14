// tb_chest_xray_cnn.v
// Self-checking testbench for chest_xray_cnn binary classifier.
//
// Simulation image size: 128×128 (16 384 pixels per image).
//   IMAGE_WIDTH=128 → W2=63 → W3=30 → W4=14 → W5=6
//   GAP_W=2  TOTAL_OUTPUTS=4  SHIFT_BITS=2
//
// Test images:
//   Test 1 — Uniform black (all 0):  zero convolutions → score≈0 → Normal (0)
//   Test 2 — Uniform grey (all 128): uniform → Sobel-x ≈ 0   → Normal (0)
//   Test 3 — Sharp vertical edge (left=0, right=255, edge at col 64):
//             strong Sobel-x response → score high → Abnormal (1)
//
// Clock: 10 ns period (100 MHz).
// Timeout guard: 500 000 cycles per image.

`timescale 1ns/1ps

module tb_chest_xray_cnn;

    // ── Parameters matching IMAGE_WIDTH=128 ───────────────────────────────────
    localparam IMG_W          = 128;
    localparam IMG_PIXELS     = IMG_W * IMG_W;   // 16 384

    // Derived GAP / FC parameters (must match chest_xray_cnn defaults when
    // IMAGE_WIDTH=128 is overridden):
    //   W2=(128-2)/2=63  W3=(63-2)/2=30  W4=(30-2)/2=14  W5=(14-2)/2=6
    //   GAP_W=(6-2)/2=2  TOTAL_OUTPUTS=4  SHIFT_BITS=2
    localparam TOTAL_OUTPUTS  = 4;
    localparam SHIFT_BITS     = 2;
    localparam ACC_WIDTH      = 28;

    // ── DUT signals ───────────────────────────────────────────────────────────
    reg        clk;
    reg        rst_n;
    reg  [7:0] pixel_in;
    reg        pixel_valid;
    wire       class_out;
    wire [7:0] score;
    wire       inference_done;
    wire       busy;

    // ── DUT instantiation ─────────────────────────────────────────────────────
    chest_xray_cnn #(
        .IMAGE_WIDTH  (IMG_W),
        .SHIFT_BITS   (SHIFT_BITS),
        .TOTAL_OUTPUTS(TOTAL_OUTPUTS),
        .ACC_WIDTH    (ACC_WIDTH)
    ) dut (
        .clk           (clk),
        .rst_n         (rst_n),
        .pixel_in      (pixel_in),
        .pixel_valid   (pixel_valid),
        .class_out     (class_out),
        .score         (score),
        .inference_done(inference_done),
        .busy          (busy)
    );

    // ── Clock: 10 ns period ───────────────────────────────────────────────────
    initial clk = 0;
    always #5 clk = ~clk;

    // ── Shared image buffer ───────────────────────────────────────────────────
    reg [7:0] cur_image [0:IMG_PIXELS-1];

    // ── Counters ──────────────────────────────────────────────────────────────
    integer pass_cnt;
    integer fail_cnt;

    // ── Task: stream cur_image and wait for result ────────────────────────────
    task run_image;
        input [8*32-1:0] label;
        input             expect_class;
        integer i;
        integer tc;
        begin
            // Flush pipeline state between images via a brief reset pulse.
            // This clears delay-line contents so each image starts from a clean state.
            pixel_valid = 0;
            pixel_in    = 8'd0;
            rst_n = 0;
            repeat (4) @(posedge clk);
            rst_n = 1;
            repeat (4) @(posedge clk);

            // Stream IMG_PIXELS pixels
            pixel_valid = 1;
            for (i = 0; i < IMG_PIXELS; i = i + 1) begin
                pixel_in = cur_image[i];
                @(posedge clk); #1;
            end
            pixel_valid = 0;
            pixel_in    = 8'd0;

            // Wait for inference_done (timeout = 500 000 cycles)
            tc = 0;
            while (!inference_done && tc < 500_000) begin
                @(posedge clk); #1;
                tc = tc + 1;
            end

            if (tc >= 500_000) begin
                $display("FAIL  %-32s  TIMEOUT", label);
                fail_cnt = fail_cnt + 1;
            end else if (class_out === expect_class) begin
                $display("PASS  %-32s  class=%0d  score=%3d",
                          label, class_out, score);
                pass_cnt = pass_cnt + 1;
            end else begin
                $display("FAIL  %-32s  got=%0d score=%3d expected=%0d",
                          label, class_out, score, expect_class);
                fail_cnt = fail_cnt + 1;
            end

            // Wait for pipeline to go idle
            while (busy) begin @(posedge clk); #1; end
            repeat (20) @(posedge clk);
        end
    endtask

    // ── Image construction ────────────────────────────────────────────────────
    integer row, col;

    // ── Main test sequence ────────────────────────────────────────────────────
    initial begin
        pass_cnt    = 0;
        fail_cnt    = 0;
        pixel_in    = 0;
        pixel_valid = 0;

        // Reset
        rst_n = 0;
        repeat (4) @(posedge clk);
        rst_n = 1;
        repeat (4) @(posedge clk);

        $display("=== chest_xray_cnn binary classifier testbench ===");
        $display("    IMAGE_WIDTH=%0d  TOTAL_OUTPUTS=%0d  SHIFT_BITS=%0d",
                  IMG_W, TOTAL_OUTPUTS, SHIFT_BITS);
        $display("    FC1: 64->16  FC2: 16->1  threshold=128");
        $display("%-6s  %-32s  %s", "Result", "Test", "Details");
        $display("──────────────────────────────────────────────────────────");

        // ── Test 1: Uniform black ─────────────────────────────────────────
        for (row = 0; row < IMG_W; row = row + 1)
            for (col = 0; col < IMG_W; col = col + 1)
                cur_image[row*IMG_W + col] = 8'd0;
        run_image("Test1: Uniform black (Normal)",    1'b0);

        // ── Test 2: Uniform grey ─────────────────────────────────────────
        for (row = 0; row < IMG_W; row = row + 1)
            for (col = 0; col < IMG_W; col = col + 1)
                cur_image[row*IMG_W + col] = 8'd128;
        run_image("Test2: Uniform grey-128 (Normal)", 1'b0);

        // ── Test 3: Sharp vertical edge at col IMG_W/2 ───────────────────
        for (row = 0; row < IMG_W; row = row + 1)
            for (col = 0; col < IMG_W; col = col + 1)
                cur_image[row*IMG_W + col] = (col >= IMG_W/2) ? 8'd255 : 8'd0;
        run_image("Test3: Sharp vert. edge (Abnorm)", 1'b1);

        // ── Test 4: Horizontal gradient (informational only) ─────────────
        for (row = 0; row < IMG_W; row = row + 1)
            for (col = 0; col < IMG_W; col = col + 1)
                cur_image[row*IMG_W + col] = col * 2;   // 0..254
        begin : t4_block
            integer t4i, t4c;
            pixel_valid = 1;
            for (t4i = 0; t4i < IMG_PIXELS; t4i = t4i + 1) begin
                pixel_in = cur_image[t4i];
                @(posedge clk); #1;
            end
            pixel_valid = 0;
            pixel_in    = 8'd0;
            t4c = 0;
            while (!inference_done && t4c < 500_000) begin
                @(posedge clk); #1;
                t4c = t4c + 1;
            end
            $display("INFO  %-32s  class=%0d  score=%3d",
                      "Test4: Horiz. gradient", class_out, score);
        end

        // ── Summary ──────────────────────────────────────────────────────────
        $display("──────────────────────────────────────────────────────────");
        $display("TOTAL: %0d PASS  %0d FAIL", pass_cnt, fail_cnt);
        if (fail_cnt == 0)
            $display("ALL TESTS PASSED");
        else
            $display("SOME TESTS FAILED");

        $finish;
    end

    // ── Waveform dump ─────────────────────────────────────────────────────────
    initial begin
        $dumpfile("sim/tb_chest_xray_cnn.vcd");
        $dumpvars(0, tb_chest_xray_cnn);
    end

    // ── Global timeout guard ──────────────────────────────────────────────────
    initial begin
        #200_000_000;   // 200 ms @ 1 ns timescale  (covers 4 × 128×128 images)
        $display("ERROR: global simulation timeout");
        $finish;
    end

endmodule
