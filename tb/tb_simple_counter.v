`timescale 1ns/1ps
module simple_counter_tb;
    reg clk;
    reg rst_n;
    reg en;
    wire [3:0] count;

    // Instantiate DUT
    simple_counter dut(
        .clk(clk),
        .rst_n(rst_n),
        .en(en),
        .count(count)
    );

    // Clock generation
    initial begin
        clk = 0;
        forever #5 clk = ~clk; // 100MHz
    end

    // Stimulus
    initial begin
        $display("Time	clk	rst_n	en	count");
        $monitor($time, "	%b	%b	%b	%h", clk, rst_n, en, count);
        rst_n = 0; en = 0;
        #20;
        rst_n = 1;
        #10;
        en = 1;
        #100;
        en = 0;
        #50;
        $finish;
    end
endmodule
