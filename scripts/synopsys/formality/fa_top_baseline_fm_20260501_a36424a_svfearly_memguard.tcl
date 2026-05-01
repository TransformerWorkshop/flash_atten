set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ../../..]]
source [file join $PROJECT_ROOT synopsys formality flow setup.tcl]

set ACTIVE_TOP FA_TOP_BASELINE
set RUN_TAG 20260501_a36424a_svfearly_memguard_rtl_vs_netlist
set REPORT_ROOT [file join $TOOL_ROOT $REPORTS_SUBDIR $ACTIVE_TOP]
set RESULT_ROOT [file join $TOOL_ROOT $RESULTS_SUBDIR $ACTIVE_TOP]
set DC_RESULT_ROOT [file join $PROJECT_ROOT $DC_SUBDIR $RESULTS_SUBDIR $ACTIVE_TOP]
set IMPL_NETLIST [file join $DC_RESULT_ROOT ${ACTIVE_TOP}_compile.v]
set POSTSYN_SVF [file join $DC_RESULT_ROOT ${ACTIVE_TOP}_compile.svf]
file mkdir $REPORT_ROOT
file mkdir $RESULT_ROOT

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

foreach required_path [concat $FORMALITY_STDCELL_LIBS [list $IMPL_NETLIST $POSTSYN_SVF]] {
    if {![file exists $required_path]} {
        puts "Missing required Formality input: $required_path"
        exit 1
    }
}

set synopsys_auto_setup true
set hdlin_unresolved_modules black_box
set search_path [list $RTL_ROOT $NOD_ROOT $LIBS_WORK_ROOT]
set_host_options -max_cores 1
set verification_effort_level high

foreach db $FORMALITY_STDCELL_LIBS {
    read_db $db
}
if {[file exists $FORMALITY_MEMORY_LIB]} {
    read_db $FORMALITY_MEMORY_LIB
}

fm_note "Using SVF $POSTSYN_SVF"
set_svf $POSTSYN_SVF

fm_note "Read reference RTL source"
read_verilog -r -define SYNTHESIS $fa_sources
set_top r:/WORK/$ACTIVE_TOP

fm_note "Read implementation gate-level Verilog $IMPL_NETLIST"
read_verilog -i $IMPL_NETLIST
set_top i:/WORK/$ACTIVE_TOP

redirect -file [file join $REPORT_ROOT ${RUN_TAG}_match.rpt] { match }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_setup_status.rpt] { report_status }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_verify.rpt] { verify }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_failing_points.rpt] { report_failing_points }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_aborted_points.rpt] { report_aborted_points }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_unverified_points.rpt] { report_unverified_points }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_status.rpt] { report_status }
save_session -replace [file join $RESULT_ROOT ${RUN_TAG}_fm_session]
exit
