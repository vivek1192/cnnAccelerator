# syn/constraints/chest_xray_zcu104.xdc
# Timing + I/O constraints for chest_xray_cnn on ZCU104 (xczu7ev-ffvc1156-2-e)
# Target clock: 100 MHz (10 ns) on PL clock pin H9

# Primary PL clock
set_property PACKAGE_PIN H9          [get_ports clk]
set_property IOSTANDARD  LVCMOS18   [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# Active-low reset (push-button SW19)
set_property PACKAGE_PIN J15         [get_ports rst_n]
set_property IOSTANDARD  LVCMOS18   [get_ports rst_n]
set_false_path -from [get_ports rst_n]

# Data I/O IOSTANDARD (LOC assigned via Pin Planner for board bring-up)
set_property IOSTANDARD LVCMOS18 [get_ports {pixel_in[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pixel_valid]
set_property IOSTANDARD LVCMOS18 [get_ports class_out]
set_property IOSTANDARD LVCMOS18 [get_ports {score[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports inference_done]
set_property IOSTANDARD LVCMOS18 [get_ports busy]
