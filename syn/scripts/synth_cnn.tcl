# syn/scripts/synth_cnn.tcl
# Vivado batch-mode synthesis — simple_cnn on ZCU104 (xczu7ev-ffvc1156-2-e)

create_project -in_memory -part xczu7ev-ffvc1156-2-e

# RTL sources — primitives first, then layers, then top
add_files rtl/core/booth_mult.v
add_files rtl/core/relu.v
add_files rtl/core/max_pool.v
add_files rtl/layers/conv_layer.v
add_files rtl/top/simple_cnn.v

# Timing constraints (ZCU104 PL clock pin)
read_xdc syn/constraints/cnn_zcu104.xdc

# Synthesize
synth_design -top simple_cnn -part xczu7ev-ffvc1156-2-e \
  -flatten_hierarchy rebuilt

# Reports
file mkdir syn/reports
report_utilization    -file syn/reports/utilization.rpt
report_timing_summary -file syn/reports/timing_summary.rpt

# Checkpoint for impl hand-off
write_checkpoint syn/reports/post_synth.dcp