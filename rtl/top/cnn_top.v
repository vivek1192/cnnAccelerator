// Top-level module for CNN Accelerator

module top #(
    parameter INPUT_WIDTH = 28,
    parameter INPUT_HEIGHT = 28,
    parameter INPUT_CHANNELS = 1,
    parameter FILTER_SIZE = 3,
    parameter OUTPUT_CHANNELS = 16
)
(
    input wire clk,
    input wire rst_n,
    input wire [INPUT_WIDTH*INPUT_HEIGHT*INPUT_CHANNELS-1:0] input_data,
    output wire [OUTPUT_WIDTH*OUTPUT_HEIGHT*OUTPUT_CHANNELS-1:0] output_data
);

    // Instantiate convolutional layer
    conv_layer #(
        .INPUT_WIDTH(INPUT_WIDTH),
        .INPUT_HEIGHT(INPUT_HEIGHT),
        .INPUT_CHANNELS(INPUT_CHANNELS),
        .FILTER_SIZE(FILTER_SIZE),
        .OUTPUT_CHANNELS(OUTPUT_CHANNELS)
    ) conv_layer_inst (
        .input_data(input_data),
        .output_data(output_data)
    );

    // Instantiate pooling layer
    pool_layer #(
        .INPUT_WIDTH(OUTPUT_WIDTH),
        .INPUT_HEIGHT(OUTPUT_HEIGHT),
        .POOL_SIZE(2)
    ) pool_layer_inst (
        .input_data(output_data),
        .output_data(pooled_data)
    );

endmodule