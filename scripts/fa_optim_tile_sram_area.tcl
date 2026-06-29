proc getenv_default {name default_value} {
    global env
    if {[info exists env($name)] && $env($name) ne ""} {
        return $env($name)
    }
    return $default_value
}

proc require_file {path label} {
    if {![file exists $path]} {
        puts "CODEX_ERROR missing $label: $path"
        exit 2
    }
}

set repo_root [getenv_default FA_REPO_ROOT [pwd]]
set top_name [getenv_default FA_TOP FA_LOCAL_TILE_SRAM_16X64X16]
set report_dir [getenv_default FA_REPORT_DIR [file join $repo_root debug dc_fa_local_tile_sram]]
set result_dir [getenv_default FA_RESULT_DIR [file join $report_dir results]]
set clock_period_ns [getenv_default FA_CLOCK_PERIOD_NS 5.0]
set std_db [getenv_default FA_STD_DB /mnt/hgfs/TSMC28/logic/tcbn28hpcplusbwp7t40p140_180b/AN61001_20180509/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp7t40p140_180a/tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs.db]
set sram_db_list [getenv_default FA_SRAM_DB_LIST ""]
set analyze_tsmc_stubs [getenv_default FA_ANALYZE_TSMC_STUBS 0]

file mkdir $report_dir
file mkdir $result_dir

require_file $std_db "standard-cell db"

set sram_dbs {}
foreach db_path $sram_db_list {
    require_file $db_path "sram db"
    lappend sram_dbs $db_path
}

set target_library [list $std_db]
set link_library [concat [list "*"] $target_library $sram_dbs]
set_app_var target_library $target_library
set_app_var link_library $link_library

set rtl_files [list \
    [file join $repo_root rtl fa_sram_hard.v] \
    [file join $repo_root rtl fa_sram_tile_buffers.v] \
]
if {$analyze_tsmc_stubs} {
    set rtl_files [linsert $rtl_files 0 [file join $repo_root rtl tsmc_sram_macros.v]]
}
foreach rtl_file $rtl_files {
    require_file $rtl_file "RTL"
}

puts "CODEX_FA_TILE_SRAM_DC_START top=$top_name"
puts "CODEX_FA_TILE_SRAM_REPO_ROOT $repo_root"
puts "CODEX_FA_TILE_SRAM_STD_DB $std_db"
puts "CODEX_FA_TILE_SRAM_SRAM_DBS $sram_dbs"

analyze -define SYNTHESIS -format sverilog $rtl_files
elaborate $top_name
current_design $top_name
link

if {[sizeof_collection [get_ports clk -quiet]] > 0} {
    create_clock -name clk -period $clock_period_ns [get_ports clk]
}
if {[sizeof_collection [get_ports rstn -quiet]] > 0} {
    set_false_path -from [get_ports rstn]
}

redirect -file [file join $report_dir check_design_pre_compile.rpt] { check_design }
redirect -file [file join $report_dir reference_pre_compile.rpt] { report_reference }

compile_ultra -no_autoungroup

redirect -file [file join $report_dir qor.rpt] { report_qor }
redirect -file [file join $report_dir area.rpt] { report_area -hierarchy }
redirect -file [file join $report_dir timing.rpt] { report_timing -max_paths 10 }
redirect -file [file join $report_dir reference.rpt] { report_reference -hierarchy }
redirect -file [file join $report_dir check_design.rpt] { check_design }

write -hierarchy -format ddc -output [file join $result_dir ${top_name}.ddc]
write_file -hierarchy -format verilog -output [file join $result_dir ${top_name}.mapped.v]

puts "CODEX_FA_TILE_SRAM_DC_DONE top=$top_name report_dir=$report_dir result_dir=$result_dir"
exit
