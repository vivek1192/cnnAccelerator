# =============================================================================
# Makefile — CNN Accelerator (cnnAccelerator)
# Industry-standard RTL project layout
#
# Directory layout:
#   rtl/core/      synthesizable primitives  (booth_mult, relu, max_pool, …)
#   rtl/layers/    CNN layer modules          (conv_layer)
#   rtl/top/       top-level integration      (simple_cnn, cnn_top)
#   tb/            testbenches                (tb_*.v)
#   tb/vectors/    test vector files
#   sim/           simulation output          (generated)
#   syn/scripts/   Vivado TCL scripts
#   syn/constraints/ XDC constraint files
#   syn/reports/   synthesis reports          (generated)
#   impl/          Vivado implementation      (generated)
#   sw/            Python model + utilities
#   docs/          documentation
# =============================================================================

VIVADO   := E:/Xilinx/2025.2/Vivado/bin/vivado.bat
IVERILOG := iverilog
VVP      := vvp

# ---- RTL sources (all synthesizable .v files, order matters for hierarchy) --
RTL_CORE   := $(wildcard rtl/core/*.v)
RTL_LAYERS := $(wildcard rtl/layers/*.v)
RTL_TOP    := $(wildcard rtl/top/*.v)
RTL_ALL    := $(RTL_CORE) $(RTL_LAYERS) $(RTL_TOP)

# ---- Testbench sources -------------------------------------------------------
TB_ALL     := $(wildcard tb/*.v)

# =============================================================================
# Simulation targets
# =============================================================================

.PHONY: sim sim_cnn sim_counter clean

## Run all simulations
sim: sim_booth sim_cnn sim_top sim_counter

## Unit test: booth_mult exhaustive 65536-case sweep
sim_booth: rtl/core/booth_mult.v tb/tb_booth_mult.v
	@mkdir -p sim
	$(IVERILOG) -g2001 -Wall \
	  -o sim/booth_mult.vvp \
	  rtl/core/booth_mult.v \
	  tb/tb_booth_mult.v
	$(VVP) sim/booth_mult.vvp

## Integration test: simple_cnn edge-detection correctness
sim_cnn: $(RTL_ALL) tb/tb_simple_cnn.v
	@mkdir -p sim
	$(IVERILOG) -g2001 -Wall \
	  -o sim/simple_cnn.vvp \
	  rtl/core/booth_mult.v \
	  rtl/core/relu.v \
	  rtl/core/max_pool.v \
	  rtl/layers/conv_layer.v \
	  rtl/top/simple_cnn.v \
	  tb/tb_simple_cnn.v
	$(VVP) sim/simple_cnn.vvp

## Integration test: structural/reset behaviour (tb_top)
sim_top: $(RTL_ALL) tb/tb_top.v
	@mkdir -p sim
	$(IVERILOG) -g2001 -Wall \
	  -o sim/tb_top.vvp \
	  rtl/core/booth_mult.v \
	  rtl/core/relu.v \
	  rtl/core/max_pool.v \
	  rtl/layers/conv_layer.v \
	  rtl/top/simple_cnn.v \
	  tb/tb_top.v
	$(VVP) sim/tb_top.vvp

## Unit test: simple_counter
sim_counter: rtl/core/simple_counter.v tb/tb_simple_counter.v
	@mkdir -p sim
	$(IVERILOG) -g2001 -Wall \
	  -o sim/simple_counter.vvp \
	  rtl/core/simple_counter.v \
	  tb/tb_simple_counter.v
	$(VVP) sim/simple_counter.vvp

# =============================================================================
# Synthesis targets (Vivado batch mode)
# =============================================================================

.PHONY: synth synth_cnn synth_counter

## Synthesize the full CNN accelerator
synth_cnn:
	$(VIVADO) -mode batch -source syn/scripts/synth_cnn.tcl

## Synthesize the simple_counter (smoke test)
synth_counter:
	$(VIVADO) -mode batch -source syn/scripts/synth_counter.tcl

# =============================================================================
# Implementation target (place & route, bitstream)
# =============================================================================

.PHONY: impl

impl:
	$(VIVADO) -mode batch -source syn/scripts/impl_cnn.tcl

# =============================================================================
# Clean
# =============================================================================

clean:
	rm -f sim/*.vvp sim/*.vcd
	rm -rf syn/reports/*
	rm -rf impl/*
	rm -rf vivado.log vivado.jou .Xil
