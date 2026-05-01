set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ../../..]]
source [file join $PROJECT_ROOT synopsys dc flow setup.tcl]

set ACTIVE_TOP FA_TOP_BASELINE
set RUN_TAG 20260501_p2_datapath_lightcheck
set REPORT_ROOT [file join $TOOL_ROOT $REPORTS_SUBDIR $ACTIVE_TOP]
set RESULT_ROOT [file join $TOOL_ROOT $RESULTS_SUBDIR $ACTIVE_TOP]
file mkdir $REPORT_ROOT
file mkdir $RESULT_ROOT

set expected_rtl_root [file normalize [file join $PROJECT_ROOT rtl]]
set actual_rtl_root [file normalize $RTL_ROOT]
if {$actual_rtl_root ne $expected_rtl_root} {
    error "RTL_ROOT must be $expected_rtl_root, got $actual_rtl_root"
}
if {[file exists [file join $PROJECT_ROOT synopsys rtl]]} {
    error "Stale shadow RTL directory exists: [file join $PROJECT_ROOT synopsys rtl]"
}

proc add_fa_source {files_var file_name required} {
    upvar $files_var files
    global RTL_ROOT
    set src [file join $RTL_ROOT $file_name]
    if {[file exists $src]} {
        lappend files $src
    } elseif {$required} {
        error "Missing required RTL source: $src"
    } else {
        puts "Optional RTL source not present: $src"
    }
}

set fa_sources {}
add_fa_source fa_sources csr_array.v 1
add_fa_source fa_sources csr_bank.v 0
add_fa_source fa_sources fa_sram_hard.v 1
add_fa_source fa_sources sync_fifo.v 0
add_fa_source fa_sources gemu_v3.v 1
add_fa_source fa_sources gemm_v3.v 1
add_fa_source fa_sources fa_axi_rd_master.v 1
add_fa_source fa_sources fa_buffers_real.v 1
add_fa_source fa_sources fa_p_bypass_real.v 1
add_fa_source fa_sources fa_core_baseline.v 1
add_fa_source fa_sources fa_cores_real.v 1
add_fa_source fa_sources fa_csr.v 1
add_fa_source fa_sources fa_dma_shell.v 1
add_fa_source fa_sources fa_oacc_update_real.v 1
add_fa_source fa_sources fa_recip_q16_16.v 1
add_fa_source fa_sources fa_row_state_real.v 1
add_fa_source fa_sources fa_run_ctrl.v 1
add_fa_source fa_sources fa_score_post_real.v 1
add_fa_source fa_sources fa_tile_sched.v 1
add_fa_source fa_sources fa_top_baseline.v 1

set source_manifest [file join $REPORT_ROOT ${RUN_TAG}_source_manifest.txt]
set fp [open $source_manifest w]
foreach src $fa_sources {
    puts $fp $src
}
close $fp

dc_note "Light DC RTL check for $ACTIVE_TOP from $RTL_ROOT"
set_host_options -max_cores 1
set_app_var hdlin_auto_save_templates false

analyze -define SYNTHESIS -format verilog $fa_sources
elaborate $ACTIVE_TOP
current_design $ACTIVE_TOP
link

source [file join $CONSTRAINTS_ROOT base.sdc]

set macro_cells [get_cells -hierarchical -quiet -filter "ref_name =~ TEM5N28HPCPLVTA64X32M4SWSO"]
if {[sizeof_collection $macro_cells] > 0} {
    set_dont_touch $macro_cells
}

redirect -file [file join $REPORT_ROOT ${RUN_TAG}_check_design.rpt] {
    check_design
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_check_timing.rpt] {
    check_timing
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_reference.rpt] {
    report_reference
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_ports_inputs_verbose.rpt] {
    report_port -verbose [all_inputs]
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_ports_outputs_verbose.rpt] {
    report_port -verbose [all_outputs]
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_clock_report.rpt] {
    report_clock -attributes
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_constraint.rpt] {
    report_constraint
}

write -hierarchy -format ddc -output [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}_elab.ddc]

dc_note "Light DC RTL check complete for $ACTIVE_TOP"
exit
