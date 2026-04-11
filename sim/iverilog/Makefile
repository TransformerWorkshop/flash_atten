top ?= tb_gemm
w ?= $(top).vcd
bin ?= build/$(top).vvp

all: sim

compile:
	@echo "Compiling files only..."
	@TOP_MODULE="$(top)" WAVE_OUT="$(abspath $(w))" VVP_OUT="$(abspath $(bin))" ./run_sim.sh compile

sim:
	@echo "Running simulation with top module: $(top)..."
	@TOP_MODULE="$(top)" WAVE_OUT="$(abspath $(w))" VVP_OUT="$(abspath $(bin))" ./run_sim.sh sim

wave:
	@echo "Opening waveform: $(w)"
	@if [ ! -f "$(w)" ]; then \
		echo "Warning: No waveform file found. Run 'make sim' first."; \
		exit 1; \
	fi
	@if command -v gtkwave >/dev/null 2>&1; then \
		gtkwave "$(w)"; \
	else \
		echo "gtkwave not found. Open $(abspath $(w)) with your preferred waveform viewer."; \
	fi

clean:
	@echo "Cleaning simulation files..."
	@rm -rf build
	@rm -f *.vcd
	@rm -f *.fst
	@rm -f *.lxt
	@rm -f *.log
	@echo "Simulation files cleaned"

info:
	@echo "Current settings:"
	@echo "  Top module: $(top)"
	@echo "  Waveform file: $(w)"
	@echo "  Output binary: $(bin)"
	@echo "  RTL directory: ../../rtl"
	@echo "  Testbench directory: ../../tb"

help:
	@echo "Available targets:"
	@echo "  all          - Default target (runs sim)"
	@echo "  compile      - Compile only"
	@echo "  sim          - Compile and run simulation"
	@echo "  wave         - Open waveform in gtkwave"
	@echo "  clean        - Remove generated simulation files"
	@echo "  info         - Show current settings"
	@echo "  help         - Show this help text"
	@echo ""
	@echo "Optional parameters:"
	@echo "  top=<module> - Select simulation top module"
	@echo "  w=<file>     - Select waveform output file"
	@echo "  bin=<file>   - Select compiled vvp output file"
	@echo ""
	@echo "Examples:"
	@echo "  make sim top=tb_gemm"
	@echo "  make sim top=tb_gemm_col w=tb_gemm_col.vcd"
	@echo "  make sim top=tb_shift_reg w=shift_reg.vcd"

.PHONY: all compile sim wave clean info help
