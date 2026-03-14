# syn/constraints/cnn_zcu104.xdc
# Timing and I/O constraints for Xilinx ZCU104 (xczu7ev-ffvc1156-2-e)
# Target clock: 100 MHz (10 ns period) on PL clock pin H9

# Primary PL clock (SYSCLK_P on ZCU104 expansion connector)
set_property PACKAGE_PIN H9          [get_ports clk]
set_property IOSTANDARD  LVCMOS18   [get_ports clk]
create_clock -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports clk]

# Active-low reset (push-button SW19 on ZCU104)
set_property PACKAGE_PIN J15         [get_ports rst_n]
set_property IOSTANDARD  LVCMOS18   [get_ports rst_n]

# False-path the async reset input to avoid timing exceptions
set_false_path -from [get_ports rst_n]

# ── Data I/O IOSTANDARD (pin LOC assigned in impl_cnn.tcl via Pin Planner) ──
# For prototype bitstream, DRC waivers are set in the impl script.
# For board bring-up, assign actual ZCU104 PMOD pins here.
set_property IOSTANDARD LVCMOS18 [get_ports {pixel_in[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pixel_valid]
set_property IOSTANDARD LVCMOS18 [get_ports {pooled_out[*]}]
set_property IOSTANDARD LVCMOS18 [get_ports pool_valid]