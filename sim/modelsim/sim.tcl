# ---------------- 项目设置（开头方便修改） ----------------
# 项目名称
set PROJECT_NAME "tpu_v1"
# RTL目录路径
set RTL_DIR "../../rtl"
# Testbench目录路径
set TB_DIR "../../tb"
# 默认顶层模块
set TOP_MODULE "tb_gemu"

# ---------------- 命令行参数处理 ----------------
# 检查是否只需编译
if {![info exists compile_only]} {
    set compile_only 0
}

# 检查是否指定了顶层模块
if {[info exists top_module]} {
    set TOP_MODULE $top_module
    puts "Using specified top module: $TOP_MODULE"
} else {
    puts "Using default top module: $TOP_MODULE"
}

# ---------------- 错误处理 ----------------
proc handle_error {message} {
    puts "Error: $message"
}

# 如果不是只编译模式，则退出当前仿真
if {!$compile_only} {
    if {[catch {
        quit -sim
    } result]} {
        # 忽略这个错误，可能是没有活动的仿真
    }
}

# ---------------- 工作库设置 ----------------
# 创建work库（如果不存在）
if {[catch {
    if {![file exists work]} {
        vlib work
    }
    vmap work work
} result]} {
    handle_error "Failed to create/map work library: $result"
    return
}

# 检查目录是否存在
if {![file exists $RTL_DIR]} {
    handle_error "RTL directory not found: $RTL_DIR"
    puts "Current directory: [pwd]"
    return
}

if {![file exists $TB_DIR]} {
    handle_error "Testbench directory not found: $TB_DIR"
    puts "Current directory: [pwd]"
    return
}

# ---------------- 文件搜索与编译 ----------------
# 查找所有Verilog文件
proc find_verilog_files {dir} {
    if {![file exists $dir]} {
        return {}
    }
    
    set result {}
    
    # 添加当前目录中的.v文件
    foreach file [glob -nocomplain [file join $dir *.v]] {
        lappend result $file
    }
    
    # 递归处理子目录
    foreach subdir [glob -nocomplain -type d [file join $dir *]] {
        set subfiles [find_verilog_files $subdir]
        set result [concat $result $subfiles]
    }
    
    return $result
}

# 收集所有需要编译的文件
set rtl_files [find_verilog_files $RTL_DIR]
set tb_files [find_verilog_files $TB_DIR]

puts "Found [llength $rtl_files] RTL files"
puts "Found [llength $tb_files] testbench files"

# 检查是否找到文件
if {[llength $rtl_files] == 0 && [llength $tb_files] == 0} {
    handle_error "No Verilog files found in $RTL_DIR or $TB_DIR"
    return
}

# 编译所有文件 - 使用eval让文件列表正确展开
puts "Compiling files with increment mode..."
if {[catch {
    eval vlog -incr $rtl_files $tb_files
} result]} {
    handle_error "Compilation failed: $result"
    return
}

# 如果是只编译模式，这里就结束
if {$compile_only} {
    puts "Compilation complete"
    return
}

# ---------------- 仿真设置与运行 ----------------
# 检查顶层模块是否存在
puts "Starting simulation with top module: $TOP_MODULE"
if {[catch {
    vsim -voptargs=+acc work.$TOP_MODULE
} result]} {
    handle_error "Failed to start simulation: $result\nPossible causes: Top module '$TOP_MODULE' doesn't exist or has compile errors."
    return
}

# 添加波形：清理旧波形并仅加载当前目录下的 wave.do
if {[catch {
    quietly delete wave *
} result]} {
    # 某些模式下可能没有现有波形窗口，忽略即可
}

if {[file exists "wave.do"]} {
    puts "Loading wave configuration from wave.do"
    if {[catch {
        do wave.do
    } result]} {
        puts "Warning: Failed to load wave.do: $result"
    }
} else {
    puts "Warning: wave.do not found, no waveform signals were added."
}

# 运行仿真
puts "Running simulation..."
run -all
puts "Simulation complete"

# 保存波形文件
if {[catch {
    write wave vsim.wlf
} result]} {
    puts "Warning: Could not save waveform file: $result"
}