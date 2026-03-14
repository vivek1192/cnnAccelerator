// Common testbench utilities

module tb_utils;

    // Function to generate random input data
    function void generate_input (output reg [7:0] data [0:27][0:27]);
        integer i, j;
        for (i=0; i<28; i=i+1) begin
            for (j=0; j<28; j=j+1) begin
                data[i][j] = $random % 256;
            end
        end
    endfunction

    // Function to monitor output data
    task monitor_output (input [7:0] data [0:13][0:13]);
        integer i, j;
        $display("Output data:");
        for (i=0; i<14; i=i+1) begin
            for (j=0; j<14; j=j+1) begin
                $write("%3d ", data[i][j]);
            end
            $display();
        end
    endtask

endmodule