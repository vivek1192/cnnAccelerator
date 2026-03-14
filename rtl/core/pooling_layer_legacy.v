module pooling_layer (
    input clk,          // Clock signal
    input rst_n,        // Active-low reset signal
    input [7:0] feature_maps [24*24-1:0], // 24x24 feature maps
    output reg [7:0] pooled_feature_maps [12*12-1:0] // 12x12 pooled feature maps
);

reg [7:0] max_val;
integer i, j;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        for (i = 0; i < 12*12; i = i + 1) begin
            pooled_feature_maps[i] <= 8'b0;
        end
    end else begin
        for (i = 0; i < 12; i = i + 1) begin
            for (j = 0; j < 12; j = j + 1) begin
                max_val <= feature_maps[(i*2)*24 + (j*2)];
                if (feature_maps[(i*2)*24 + (j*2) + 1] > max_val)
                    max_val <= feature_maps[(i*2)*24 + (j*2) + 1];
                if (feature_maps[(i*2 + 1)*24 + (j*2)] > max_val)
                    max_val <= feature_maps[(i*2 + 1)*24 + (j*2)];
                if (feature_maps[(i*2 + 1)*24 + (j*2) + 1] > max_val)
                    max_val <= feature_maps[(i*2 + 1)*24 + (j*2) + 1];
                pooled_feature_maps[i*12 + j] <= max_val;
            end
        end
    end
end

endmodule