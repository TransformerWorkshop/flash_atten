# 默认设置
top ?= tb_gemu
w ?= wave.do
PROJECT_NAME ?= flash_atten

all: sim wave

# 只编译不运行
compile:
	@echo "Compiling files only..."
	@vsim -c -do "set compile_only 1; do sim.tcl; quit -f"

# 运行仿真
sim: 
	@echo "Running simulation with top module: $(top)..."
	@vsim -c -do "set compile_only 0; set top_module \"$(top)\"; do sim.tcl; quit -f"

# 只创建/打开工程，不开始仿真
gui:
	@echo "Creating/opening project ($(PROJECT_NAME)) with top module: $(top)..."
	@vsim -c -do "set top_module \"$(top)\"; set project_name \"$(PROJECT_NAME)\"; do project.tcl; quit -f"
	@echo "ModelSim project created successfully. Running ModelSim GUI..."
	@vsim -gui -do "source vsim_init.do" $(PROJECT_NAME).mpf

# 查看已保存的波形文件
wave:

	@echo "Opening waveform viewer with saved wave configuration..."
	@if not exist vsim.wlf ( echo "Warning: No waveform file found. Run 'make sim' first." && exit 1 )
	@if exist wave.do ( vsim -do "source vsim_init.do; dataset open vsim.wlf; do wave.do" ) else ( vsim -do "source vsim_init.do; dataset open vsim.wlf" )

# 清理编译生成的库和仿真文件
clean:
	@echo "Cleaning simulation files..."
	@if [ -d work ]; then \
		vsim -c -do "vdel -all -lib work; quit -f"; \
	fi
	@rm -rf work
	@rm -f transcript
	@rm -f vsim.wlf
	@rm -f *.vcd
	@rm -f *.log
	@rm -f project_log.txt
	@echo "Simulation files cleaned"

# 清理所有生成文件，包括项目文件
clean_all: clean
	@echo "Cleaning all generated files including project files..."
	@rm -f *.mpf
	@rm -f *.mti
	@rm -f *.vstf
	@rm -f *.wlf
	@rm -f *.ini
	@rm -f modelsim.ini
	@echo "All files cleaned"

# 显示当前设置信息
info:
	@echo "当前设置:"
	@echo "  项目名称: $(PROJECT_NAME)"
	@echo "  顶层模块: $(top)"
	@echo "  波形配置: $(w)"
	@echo "  RTL目录: ../rtl"
	@echo "  Testbench目录: ../tb"

# 显示帮助信息
help:
	@echo "可用目标:"
	@echo "  all          - 默认目标(执行sim)"
	@echo "  compile      - 只编译不运行仿真"
	@echo "  sim          - 命令行模式下编译并运行仿真"
	@echo "  gui          - 创建/打开ModelSim工程(便于查看所有信号，包括数组)"
	@echo "  wave         - 查看波形文件"
	@echo "  clean        - 清理仿真生成文件"
	@echo "  clean_all    - 清理所有生成文件(包括项目文件)"
	@echo "  info         - 显示当前设置信息"
	@echo "  help         - 显示此帮助信息"
	@echo ""
	@echo "可选参数:"
	@echo "  top=<模块名> - 指定仿真顶层模块"
	@echo "  例如: make sim top=tb_fifo_array"
	@echo "  w=<文件名> - 指定波形配置文件"
	@echo "  例如: make wave w=my_waves.do"
	@echo "  PROJECT_NAME=<名称> - 指定工程名称"
	@echo "  例如: make gui PROJECT_NAME=my_tpu"

.PHONY: sim all wave clean clean_all compile gui help info