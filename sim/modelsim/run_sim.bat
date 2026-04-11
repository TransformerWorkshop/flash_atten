@echo off
REM filepath: d:\Project\FPGA\tpu-v1\sim\run_sim.bat
setlocal enabledelayedexpansion

REM 默认设置
set TOP_MODULE=tb_gemm
set WAVE_CFG=wave.do

REM 解析命令行参数
:parse_args
if "%1"=="" goto :done_args
if /i "%1"=="top_module" (
    set TOP_MODULE=%2
    shift
    shift
    goto :parse_args
)
if /i "%1"=="wave_cfg" (
    set WAVE_CFG=%2
    shift
    shift
    goto :parse_args
)
:done_args

REM 显示帮助
if /i "%1"=="help" (
    echo 可用命令:
    echo   run_sim.bat compile            - 只编译不运行仿真
    echo   run_sim.bat sim                - 命令行模式下编译并运行仿真
    echo   run_sim.bat gui                - GUI模式下编译并运行仿真
    echo   run_sim.bat wave               - 查看波形文件
    echo   run_sim.bat clean              - 清理编译生成物
    echo   run_sim.bat help               - 显示此帮助信息
    echo.
    echo 可选参数:
    echo   top_module ^<模块名^>          - 指定仿真顶层模块
    echo   例如: run_sim.bat gui top_module tb_fifo_array
    echo   wave_cfg ^<文件名^>            - 指定波形配置文件
    echo   例如: run_sim.bat wave wave_cfg my_waves.do
    goto :eof
)

REM 编译
if /i "%1"=="compile" (
    echo Compiling files only...
    vsim -c -do "set compile_only 1; do sim.tcl; quit -f"
    goto :eof
)

REM 仿真
if /i "%1"=="sim" (
    echo Running simulation with top module: %TOP_MODULE%...
    vsim -c -do "set compile_only 0; set top_module \"%TOP_MODULE%\"; do sim.tcl; quit -f"
    goto :eof
)

REM GUI仿真
if /i "%1"=="gui" (
    echo Running simulation with GUI, top module: %TOP_MODULE%...
    start vsim -do "source vsim_init.do; set compile_only 0; set top_module \"%TOP_MODULE%\"; do sim.tcl"
    goto :eof
)

REM 查看波形
if /i "%1"=="wave" (
    echo Opening waveform viewer with saved wave configuration...
    if exist "%WAVE_CFG%" (
        start vsim -do "source vsim_init.do; dataset open vsim.wlf; if {[file exists {%WAVE_CFG%}]} {do {%WAVE_CFG%}}"
    ) else (
        start vsim -do "source vsim_init.do; dataset open vsim.wlf"
    )
    goto :eof
)

REM 清理
if /i "%1"=="clean" (
    echo Cleaning work library...
    if exist work (
        vsim -c -do "vdel -all -lib work; quit -f"
    )
    if exist work rmdir /s /q work
    if exist transcript del /q transcript
    if exist vsim.wlf del /q vsim.wlf
    echo Clean complete
    goto :eof
)

REM 默认行为
if "%1"=="" (
    echo No command specified. Running default simulation...
    call %0 sim
    goto :eof
)

REM 未知命令
echo Unknown command: %1
echo Use 'run_sim.bat help' to see available commands.
