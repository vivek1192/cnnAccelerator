# syn/scripts/synth_counter.tcl
# Vivado batch-mode synthesis — simple_counter smoke test

create_project -in_memory -part xczu7ev-ffvc1156-2-e

add_files rtl/core/simple_counter.v
read_xdc syn/constraints/cnn_zcu104.xdc

synth_design -top simple_counter -part xczu7ev-ffvc1156-2-e

file mkdir syn/reports
write_checkpoint syn/reports/post_synth_counter.dcp
