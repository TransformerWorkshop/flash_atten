set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ../../..]]
source [file join $PROJECT_ROOT synopsys dc flow setup.tcl]

set ACTIVE_TOP FA_TOP_BASELINE
set RUN_TAG 20260501_a36424a_svfearly_memguard
set REPORT_ROOT [file join $TOOL_ROOT $REPORTS_SUBDIR $ACTIVE_TOP]
set RESULT_ROOT [file join $TOOL_ROOT $RESULTS_SUBDIR $ACTIVE_TOP]
file mkdir $REPORT_ROOT
file mkdir $RESULT_ROOT
set svf_file [file join $RESULT_ROOT ${ACTIVE_TOP}_compile.svf]

# Generate SVF guidance that is friendlier to Formality hierarchy matching.
set_app_var hdlin_enable_hier_map true
set_app_var hdlin_auto_save_templates false
set hdlin_ignore_embedded_configuration true

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
foreach src $fa_sources { puts $fp $src }
close $fp

dc_note "Analyze and elaborate $ACTIVE_TOP with FA-only source list and hier-map SVF support"
analyze -define SYNTHESIS -format verilog $fa_sources
elaborate $ACTIVE_TOP
current_design $ACTIVE_TOP
link
set_svf $svf_file
set_verification_top

redirect -file [file join $REPORT_ROOT ${RUN_TAG}_check_design_precompile.rpt] { check_design }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_unresolved_refs_precompile.rpt] { report_reference }
write -hierarchy -format ddc -output [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}_elab.ddc]
write_file -format verilog -hierarchy -output [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}_elab.v]

if {[llength $target_library] == 0} {
    puts "target_library is empty; cannot compile."
    exit 1
}

source [file join $CONSTRAINTS_ROOT base.sdc]
# 2M NAND2 equivalent target: 2000000 * 0.294 = 588000 cell area.
set_max_area 588000

set macro_cells [get_cells -hierarchical -quiet -filter "ref_name =~ TEM5N28HPCPLVTA64X32M4SWSO"]
if {[sizeof_collection $macro_cells] > 0} {
    set_dont_touch $macro_cells
}

set_host_options -max_cores 8
uniquify
set_fix_multiple_port_nets -all -buffer_constants [current_design]
compile_ultra -no_autoungroup

redirect -file [file join $REPORT_ROOT compile_qor.rpt] { report_qor }
redirect -file [file join $REPORT_ROOT compile_area.rpt] { report_area -hierarchy }
redirect -file [file join $REPORT_ROOT compile_timing.rpt] { report_timing -max_paths 20 }
redirect -file [file join $REPORT_ROOT compile_timing_20_full.rpt] { report_timing -path full -delay max -nets -max_paths 20 -transition_time -capacitance }
redirect -file [file join $REPORT_ROOT compile_constraint_summary.rpt] { report_constraint -all_violators }
redirect -file [file join $REPORT_ROOT compile_max_transition_violators.rpt] { report_constraint -all_violators -verbose -max_transition }
redirect -file [file join $REPORT_ROOT compile_max_cap_violators.rpt] { report_constraint -all_violators -verbose -max_capacitance }
redirect -file [file join $REPORT_ROOT compile_check_design.rpt] { check_design }
redirect -file [file join $REPORT_ROOT post_compile_reference.rpt] { report_reference }

write -hierarchy -format ddc -output [file join $RESULT_ROOT ${ACTIVE_TOP}_compile.ddc]
write_file -format verilog -hierarchy -output [file join $RESULT_ROOT ${ACTIVE_TOP}_compile.v]
set_svf -off

dc_note "FA_TOP_BASELINE compile complete for $RUN_TAG"
exit
