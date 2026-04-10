# 首先设置默认项目参数
set PROJECT_NAME "tpu_v1"
set RTL_DIR "../../rtl"
set TB_DIR "../../tb"
set TOP_MODULE "tb_gemu"

# 如果有命令行参数传入，则覆盖默认值
if {[info exists top_module]} {
    set TOP_MODULE $top_module
    puts "Using specified top module: $TOP_MODULE"
}

if {[info exists project_name]} {
    set PROJECT_NAME $project_name
    puts "Using specified project name: $PROJECT_NAME"
}

# 查找所有Verilog文件函数
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

# 收集所有RTL和Testbench文件
set rtl_files [find_verilog_files $RTL_DIR]
set tb_files [find_verilog_files $TB_DIR]

# 如果工程已存在，先关闭
if {[file exists ${PROJECT_NAME}.mpf]} {
    project close
}

# 创建/打开工程
if {[file exists ${PROJECT_NAME}.mpf]} {
    project open ${PROJECT_NAME}.mpf
} else {
    project new . ${PROJECT_NAME}
}

# 将文件添加到工程
foreach file $rtl_files {
    project addfile $file
}

foreach file $tb_files {
    project addfile $file
}

# 确保退出，释放命令行
# quit -f