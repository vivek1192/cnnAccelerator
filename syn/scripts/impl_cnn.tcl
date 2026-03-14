# syn/scripts/impl_cnn.tcl
# Full implementation flow: synth → opt → place → route → bitstream
# Target: simple_cnn on ZCU104 (xczu7ev-ffvc1156-2-e) at 100 MHz
#
# Usage (from project root):
#   E:/Xilinx/2025.2/Vivado/bin/vivado.bat -mode batch -source syn/scripts/impl_cnn.tcl

file mkdir syn/reports
file mkdir impl

# ── 1. Create in-memory project ───────────────────────────────────────────────
create_project -in_memory -part xczu7ev-ffvc1156-2-e

# ── 2. Add RTL sources (primitives first) ─────────────────────────────────────
add_files rtl/core/booth_mult.v
add_files rtl/core/relu.v
add_files rtl/core/max_pool.v
add_files rtl/layers/conv_layer.v
add_files rtl/top/simple_cnn.v

read_xdc syn/constraints/cnn_zcu104.xdc

# ── 3. Synthesis ──────────────────────────────────────────────────────────────
synth_design -top simple_cnn -part xczu7ev-ffvc1156-2-e \
  -flatten_hierarchy rebuilt

report_utilization    -file syn/reports/utilization_synth.rpt
report_timing_summary -file syn/reports/timing_synth.rpt
write_checkpoint -force syn/reports/post_synth.dcp
puts "INFO: Synthesis complete."

# ── 4. Optimisation ───────────────────────────────────────────────────────────
opt_design
report_utilization    -file syn/reports/utilization_opt.rpt
write_checkpoint -force syn/reports/post_opt.dcp
puts "INFO: opt_design complete."

# ── 5. Placement ──────────────────────────────────────────────────────────────
place_design
report_utilization    -file syn/reports/utilization_place.rpt
report_timing_summary -file syn/reports/timing_place.rpt
write_checkpoint -force syn/reports/post_place.dcp
puts "INFO: place_design complete."

# ── 6. Physical optimisation (fixes hold violations) ─────────────────────────
phys_opt_design
write_checkpoint -force syn/reports/post_physopt.dcp
puts "INFO: phys_opt_design complete."

# ── 7. Routing ────────────────────────────────────────────────────────────────
route_design
report_utilization    -file syn/reports/utilization_route.rpt
report_timing_summary -file syn/reports/timing_route.rpt
report_io             -file syn/reports/io.rpt
report_power          -file syn/reports/power.rpt
write_checkpoint -force syn/reports/post_route.dcp
puts "INFO: route_design complete."

# ── 8. Bitstream ──────────────────────────────────────────────────────────────
# Prototype waiver: allow bitstream without full pin-LOC assignment.
# Remove these two lines when deploying to a physical board.
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

write_bitstream -force impl/simple_cnn.bit
puts "INFO: Bitstream written to impl/simple_cnn.bit"

puts "\n======================================================"
puts "Implementation complete. Key reports in syn/reports/:"
puts "  timing_route.rpt  — final setup + hold timing"
puts "  utilization_route.rpt — final resource usage"
puts "  power.rpt         — power estimate"
puts "======================================================"
