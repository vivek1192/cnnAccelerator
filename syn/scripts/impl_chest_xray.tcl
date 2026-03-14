# syn/scripts/impl_chest_xray.tcl
# Full implementation flow for chest_xray_cnn binary classifier.
# Target: ZCU104 (xczu7ev-ffvc1156-2-e) @ 100 MHz
#
# Usage (from project root):
#   E:/Xilinx/2025.2/Vivado/bin/vivado.bat -mode batch -source syn/scripts/impl_chest_xray.tcl

file mkdir syn/reports
file mkdir impl

# ── 1. In-memory project ──────────────────────────────────────────────────────
create_project -in_memory -part xczu7ev-ffvc1156-2-e

# ── 2. RTL sources ────────────────────────────────────────────────────────────
add_files rtl/core/booth_mult.v
add_files rtl/core/relu.v
add_files rtl/core/max_pool.v
add_files rtl/core/fc_layer.v
add_files rtl/core/global_avg_pool.v
add_files rtl/layers/conv_layer.v
add_files rtl/layers/conv_block.v
add_files rtl/top/chest_xray_cnn.v

# Weight ROM files (for $readmemh — add as data files so Vivado locates them)
add_files syn/weights/cb1_weights.mem
add_files syn/weights/cb2_weights.mem
add_files syn/weights/cb3_weights.mem
add_files syn/weights/cb4_weights.mem
add_files syn/weights/cb5_weights.mem
add_files syn/weights/fc1_weights.mem
add_files syn/weights/fc1_biases.mem
add_files syn/weights/fc2_weights.mem
add_files syn/weights/fc2_biases.mem

read_xdc syn/constraints/chest_xray_zcu104.xdc

# ── 3. Synthesis ──────────────────────────────────────────────────────────────
synth_design -top chest_xray_cnn -part xczu7ev-ffvc1156-2-e \
  -flatten_hierarchy rebuilt

report_utilization    -file syn/reports/cxr_utilization_synth.rpt
report_timing_summary -file syn/reports/cxr_timing_synth.rpt
write_checkpoint -force syn/reports/cxr_post_synth.dcp
puts "INFO: Synthesis complete."

# ── 4. Optimisation ───────────────────────────────────────────────────────────
opt_design
report_utilization    -file syn/reports/cxr_utilization_opt.rpt
write_checkpoint -force syn/reports/cxr_post_opt.dcp
puts "INFO: opt_design complete."

# ── 5. Placement ──────────────────────────────────────────────────────────────
place_design
report_utilization    -file syn/reports/cxr_utilization_place.rpt
report_timing_summary -file syn/reports/cxr_timing_place.rpt
write_checkpoint -force syn/reports/cxr_post_place.dcp
puts "INFO: place_design complete."

# ── 6. Physical optimisation ──────────────────────────────────────────────────
phys_opt_design
write_checkpoint -force syn/reports/cxr_post_physopt.dcp
puts "INFO: phys_opt_design complete."

# ── 7. Routing ────────────────────────────────────────────────────────────────
route_design
report_utilization    -file syn/reports/cxr_utilization_route.rpt
report_timing_summary -file syn/reports/cxr_timing_route.rpt
report_power          -file syn/reports/cxr_power.rpt
write_checkpoint -force syn/reports/cxr_post_route.dcp
puts "INFO: route_design complete."

# ── 8. Bitstream ──────────────────────────────────────────────────────────────
set_property SEVERITY {Warning} [get_drc_checks NSTD-1]
set_property SEVERITY {Warning} [get_drc_checks UCIO-1]

write_bitstream -force impl/chest_xray_cnn.bit
puts "INFO: Bitstream written to impl/chest_xray_cnn.bit"

puts "\n======================================================"
puts "Implementation complete. Key reports in syn/reports/:"
puts "  cxr_timing_route.rpt      — setup + hold timing"
puts "  cxr_utilization_route.rpt — LUT / FF / DSP / BRAM usage"
puts "  cxr_power.rpt             — power estimate"
puts "======================================================"
