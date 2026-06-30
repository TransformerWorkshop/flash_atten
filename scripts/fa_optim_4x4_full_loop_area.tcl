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

proc get_lib_cell_area_or_zero {pattern} {
    set lib_cells [get_lib_cells -quiet $pattern]
    if {[sizeof_collection $lib_cells] == 0} {
        return 0.0
    }
    return [get_attribute [index_collection $lib_cells 0] area]
}

proc get_area_report_value_or_zero {report_path label} {
    if {![file exists $report_path]} {
        return 0.0
    }
    set fp [open $report_path "r"]
    set prefix "${label}:"
    set value 0.0
    while {[gets $fp line] >= 0} {
        if {[string first $prefix $line] == 0} {
            set fields [split [string trim [string range $line [string length $prefix] end]]]
            if {[llength $fields] > 0 && [string is double -strict [lindex $fields 0]]} {
                set value [lindex $fields 0]
                break
            }
        }
    }
    close $fp
    return $value
}

proc write_macro_floor_log {report_dir nand2_ref} {
    set nand2_area [get_attribute [get_lib_cells $nand2_ref] area]
    set sram256x64_area [get_lib_cell_area_or_zero */TEM5N28HPCPLVTA256X64M4SWSO]
    set k_sram_count 16
    set v_sram_count 16
    set total_sram_count [expr {$k_sram_count + $v_sram_count}]
    set k_sram_area [expr {$sram256x64_area * $k_sram_count}]
    set v_sram_area [expr {$sram256x64_area * $v_sram_count}]
    set total_sram_area [expr {$sram256x64_area * $total_sram_count}]
    set k_sram_nand2 0.0
    set v_sram_nand2 0.0
    set total_sram_nand2 0.0
    if {$nand2_area > 0.0} {
        set k_sram_nand2 [expr {$k_sram_area / $nand2_area}]
        set v_sram_nand2 [expr {$v_sram_area / $nand2_area}]
        set total_sram_nand2 [expr {$total_sram_area / $nand2_area}]
    }
    set floor_log [open [file join $report_dir precompile_macro_floor_nand2.log] "w"]
    puts $floor_log "CODEX_FA_OPTIM_FULL_LOOP_PRECOMPILE_MACRO_FLOOR_NAND2 ref=$nand2_ref nand2_area=$nand2_area sram256x64_area=$sram256x64_area k_sram_count=$k_sram_count k_sram_area=$k_sram_area k_sram_nand2=$k_sram_nand2 v_sram_count=$v_sram_count v_sram_area=$v_sram_area v_sram_nand2=$v_sram_nand2 total_sram_count=$total_sram_count total_sram_area=$total_sram_area total_sram_nand2=$total_sram_nand2"
    close $floor_log
    puts "CODEX_FA_OPTIM_FULL_LOOP_PRECOMPILE_MACRO_FLOOR_NAND2 ref=$nand2_ref nand2_area=$nand2_area sram256x64_area=$sram256x64_area k_sram_count=$k_sram_count k_sram_area=$k_sram_area k_sram_nand2=$k_sram_nand2 v_sram_count=$v_sram_count v_sram_area=$v_sram_area v_sram_nand2=$v_sram_nand2 total_sram_count=$total_sram_count total_sram_area=$total_sram_area total_sram_nand2=$total_sram_nand2"
}

proc write_hier_area_log {report_dir nand2_ref} {
    set nand2_area [get_attribute [get_lib_cells $nand2_ref] area]
    set sram256x64_area [get_lib_cell_area_or_zero */TEM5N28HPCPLVTA256X64M4SWSO]
    set total_sram_count 32
    set total_sram_area [expr {$sram256x64_area * $total_sram_count}]
    set total_sram_nand2 0.0
    if {$nand2_area > 0.0} {
        set total_sram_nand2 [expr {$total_sram_area / $nand2_area}]
    }

    set top_cell_count [sizeof_collection [get_cells]]
    set hier_cell_count [sizeof_collection [get_cells -hierarchical]]
    set reg_count [sizeof_collection [all_registers]]

    set hier_log [open [file join $report_dir hier_area_nand2.log] "w"]
    puts $hier_log "CODEX_FA_OPTIM_FULL_LOOP_DC_HIER_AREA full_mapped=0 ref=$nand2_ref nand2_area=$nand2_area total_sram_count=$total_sram_count total_sram_area=$total_sram_area total_sram_nand2=$total_sram_nand2 top_cell_count=$top_cell_count hier_cell_count=$hier_cell_count register_count=$reg_count q_tile_core=FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE"
    close $hier_log
    puts "CODEX_FA_OPTIM_FULL_LOOP_DC_HIER_AREA full_mapped=0 ref=$nand2_ref nand2_area=$nand2_area total_sram_count=$total_sram_count total_sram_area=$total_sram_area total_sram_nand2=$total_sram_nand2 top_cell_count=$top_cell_count hier_cell_count=$hier_cell_count register_count=$reg_count q_tile_core=FA_OPTIM_4X4_Q_TILE_STAGGERED_CORE"
}

set repo_root [getenv_default FA_REPO_ROOT [pwd]]
set top_name [getenv_default FA_TOP FA_OPTIM_4X4_FULL_LOOP]
set report_dir [getenv_default FA_REPORT_DIR [file join $repo_root debug dc_fa_optim_4x4_full_loop]]
set result_dir [getenv_default FA_RESULT_DIR [file join $report_dir results]]
set clock_period_ns [getenv_default FA_CLOCK_PERIOD_NS 5.0]
set compile_mode [getenv_default FA_COMPILE_MODE ultra]
set std_db [getenv_default FA_STD_DB /mnt/hgfs/TSMC28/logic/tcbn28hpcplusbwp7t40p140_180b/AN61001_20180509/TSMCHOME/digital/Front_End/timing_power_noise/CCS/tcbn28hpcplusbwp7t40p140_180a/tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs.db]
set sram_db_list [getenv_default FA_SRAM_DB_LIST ""]
set analyze_tsmc_stubs [getenv_default FA_ANALYZE_TSMC_STUBS 0]
set nand2_ref [getenv_default FA_NAND2_REF tcbn28hpcplusbwp7t40p140ffg0p99v0c_ccs/ND2D0BWP7T40P140]

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
    [file join $repo_root rtl fa_optim_4x4_full_loop.v] \
    [file join $repo_root rtl fa_optim_4x4_q_tile_staggered_core.v] \
    [file join $repo_root rtl gemm_v3.v] \
    [file join $repo_root rtl gemu_v3.v] \
    [file join $repo_root rtl fa_score_post_real.v] \
    [file join $repo_root rtl fa_row_state_real.v] \
    [file join $repo_root rtl fa_recip_q16_16.v] \
    [file join $repo_root rtl fa_p_bypass_real.v] \
    [file join $repo_root rtl fa_oacc_update_real.v] \
]
if {$analyze_tsmc_stubs} {
    set rtl_files [linsert $rtl_files 0 [file join $repo_root rtl tsmc_sram_macros.v]]
}

foreach rtl_file $rtl_files {
    require_file $rtl_file "RTL"
}

puts "CODEX_FA_OPTIM_FULL_LOOP_DC_START top=$top_name"
puts "CODEX_FA_OPTIM_FULL_LOOP_REPO_ROOT $repo_root"
puts "CODEX_FA_OPTIM_FULL_LOOP_STD_DB $std_db"
puts "CODEX_FA_OPTIM_FULL_LOOP_SRAM_DBS $sram_dbs"
puts "CODEX_FA_OPTIM_FULL_LOOP_NAND2_REF $nand2_ref"
puts "CODEX_FA_OPTIM_FULL_LOOP_COMPILE_MODE $compile_mode"

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
write_macro_floor_log $report_dir $nand2_ref

if {$compile_mode eq "precompile_only"} {
    puts "CODEX_FA_OPTIM_FULL_LOOP_DC_PRECOMPILE_ONLY_DONE top=$top_name report_dir=$report_dir"
    exit
}

if {$compile_mode eq "hier_area"} {
    write_hier_area_log $report_dir $nand2_ref
    puts "CODEX_FA_OPTIM_FULL_LOOP_DC_HIER_AREA_DONE top=$top_name report_dir=$report_dir"
    exit
}

if {$compile_mode eq "exact_map"} {
    compile -exact_map
} elseif {$compile_mode eq "quick"} {
    compile -map_effort low -area_effort low
} else {
    compile_ultra -no_autoungroup
}

set area_report_path [file join $report_dir area.rpt]
redirect -file [file join $report_dir qor.rpt] { report_qor }
redirect -file $area_report_path { report_area -hierarchy }
redirect -file [file join $report_dir timing.rpt] { report_timing -max_paths 10 }
redirect -file [file join $report_dir reference.rpt] { report_reference -hierarchy }
redirect -file [file join $report_dir check_design.rpt] { check_design }

set nand2_area [get_attribute [get_lib_cells $nand2_ref] area]
set total_area [get_attribute [current_design] area]
set total_area_source current_design_area
if {![string is double -strict $total_area]} {
    set total_area [get_area_report_value_or_zero $area_report_path "Total cell area"]
    set total_area_source area_report_total_cell_area
} elseif {$total_area == 0.0} {
    set total_area [get_area_report_value_or_zero $area_report_path "Total cell area"]
    set total_area_source area_report_total_cell_area
}
set macro_area [get_area_report_value_or_zero $area_report_path "Macro/Black Box area"]
set logic_area [expr {$total_area - $macro_area}]
set total_nand2 0.0
set macro_nand2 0.0
set logic_nand2 0.0
if {$nand2_area > 0.0} {
    set total_nand2 [expr {$total_area / $nand2_area}]
    set macro_nand2 [expr {$macro_area / $nand2_area}]
    set logic_nand2 [expr {$logic_area / $nand2_area}]
}
set nand2_log [open [file join $report_dir nand2_area.log] "w"]
puts $nand2_log "CODEX_FA_OPTIM_FULL_LOOP_DC_NAND2 full_mapped=1 ref=$nand2_ref nand2_area=$nand2_area total_area=$total_area total_area_source=$total_area_source total_nand2=$total_nand2 macro_area=$macro_area macro_nand2=$macro_nand2 logic_area=$logic_area logic_nand2=$logic_nand2"
close $nand2_log
puts "CODEX_FA_OPTIM_FULL_LOOP_DC_NAND2 full_mapped=1 ref=$nand2_ref nand2_area=$nand2_area total_area=$total_area total_area_source=$total_area_source total_nand2=$total_nand2 macro_area=$macro_area macro_nand2=$macro_nand2 logic_area=$logic_area logic_nand2=$logic_nand2"

write -hierarchy -format ddc -output [file join $result_dir ${top_name}.ddc]
write_file -hierarchy -format verilog -output [file join $result_dir ${top_name}.mapped.v]

puts "CODEX_FA_OPTIM_FULL_LOOP_DC_DONE top=$top_name report_dir=$report_dir result_dir=$result_dir"
exit
