# syn/scripts/sim_xsim.tcl
# Run simple_cnn testbench using Vivado xsim (no iverilog needed).
#
# Usage from project root:
#   C:/Xilinx/Vivado/2023.1/bin/vivado.bat -mode batch -source syn/scripts/sim_xsim.tcl
#
# Outputs:
#   sim/xsim_simple_cnn.log   — simulation transcript
#   sim/simple_cnn.wdb        — waveform database (open in Vivado GUI)

file mkdir sim

# ---- Compile RTL (primitives → layers → top) --------------------------------
xvlog -work cnn_lib rtl/core/booth_mult.v
xvlog -work cnn_lib rtl/core/relu.v
xvlog -work cnn_lib rtl/core/max_pool.v
xvlog -work cnn_lib rtl/layers/conv_layer.v
xvlog -work cnn_lib rtl/top/simple_cnn.v

# ---- Compile testbench -------------------------------------------------------
xvlog -work cnn_lib tb/tb_booth_mult.v
xvlog -work cnn_lib tb/tb_simple_cnn.v
xvlog -work cnn_lib tb/tb_top.v

# ---- Elaborate ---------------------------------------------------------------
xelab -work cnn_lib simple_cnn_tb -s sim_simple_cnn -timescale 1ns/1ps
xelab -work cnn_lib tb_booth_mult  -s sim_booth_mult  -timescale 1ns/1ps
xelab -work cnn_lib tb_top         -s sim_tb_top      -timescale 1ns/1ps

# ---- Simulate ----------------------------------------------------------------
puts "\n=== Running tb_booth_mult ==="
xsim sim_booth_mult -R -log sim/booth_mult.log

puts "\n=== Running simple_cnn_tb ==="
xsim sim_simple_cnn -R -log sim/simple_cnn.log

puts "\n=== Running tb_top ==="
xsim sim_tb_top -R -log sim/tb_top.log

puts "\nAll simulations complete. Logs in sim/"