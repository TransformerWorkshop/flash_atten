set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ../../..]]
source [file join $PROJECT_ROOT synopsys formality flow setup.tcl]

set ACTIVE_TOP FA_TOP_BASELINE
set REPORT_ROOT [file join $TOOL_ROOT $REPORTS_SUBDIR $ACTIVE_TOP]
set RESULT_ROOT [file join $TOOL_ROOT $RESULTS_SUBDIR $ACTIVE_TOP]
set DC_RESULT_ROOT [file join $PROJECT_ROOT $DC_SUBDIR $RESULTS_SUBDIR $ACTIVE_TOP]
set IMPL_NETLIST [file join $DC_RESULT_ROOT ${ACTIVE_TOP}_compile.v]
set POSTSYN_SVF [file join $DC_RESULT_ROOT ${ACTIVE_TOP}_compile.svf]
file mkdir $REPORT_ROOT
file mkdir $RESULT_ROOT

set RUN_TAG 20260430_1710_currentrtl_rtl_vs_netlist

fm_note "Formality RTL source vs compiled gate-level Verilog verification for $ACTIVE_TOP"

set fa_sources [list \
    [file join $RTL_ROOT csr_array.v] \
    [file join $RTL_ROOT csr_bank.v] \
    [file join $RTL_ROOT fa_sram_hard.v] \
    [file join $RTL_ROOT sync_fifo.v] \
    [file join $RTL_ROOT gemu_v3.v] \
    [file join $RTL_ROOT gemm_v3.v] \
    [file join $RTL_ROOT fa_axi_rd_master.v] \
    [file join $RTL_ROOT fa_buffers_real.v] \
    [file join $RTL_ROOT fa_p_bypass_real.v] \
    [file join $RTL_ROOT fa_core_baseline.v] \
    [file join $RTL_ROOT fa_cores_real.v] \
    [file join $RTL_ROOT fa_csr.v] \
    [file join $RTL_ROOT fa_dma_shell.v] \
    [file join $RTL_ROOT fa_oacc_update_real.v] \
    [file join $RTL_ROOT fa_recip_q16_16.v] \
    [file join $RTL_ROOT fa_row_state_real.v] \
    [file join $RTL_ROOT fa_run_ctrl.v] \
    [file join $RTL_ROOT fa_score_post_real.v] \
    [file join $RTL_ROOT fa_tile_sched.v] \
    [file join $RTL_ROOT fa_top_baseline.v] \
]

foreach required_path [concat $FORMALITY_STDCELL_LIBS [list $IMPL_NETLIST $POSTSYN_SVF]] {
    if {![file exists $required_path]} {
        puts "Missing required Formality input: $required_path"
        exit 1
    }
}
foreach src $fa_sources {
    if {![file exists $src]} {
        puts "Missing RTL source: $src"
        exit 1
    }
}

set synopsys_auto_setup true
set hdlin_unresolved_modules black_box
set search_path [list $RTL_ROOT $NOD_ROOT $LIBS_WORK_ROOT]

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
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_status.rpt] { report_status }
save_session -replace [file join $RESULT_ROOT ${RUN_TAG}_fm_session]
exit
