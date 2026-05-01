# Next DC run add-on for FA_TOP_BASELINE after the P0/P1 RTL cleanup.
# Source this after elaborate/link and base.sdc, before compile_ultra.
# Expected variables from the current flow: ACTIVE_TOP, RUN_TAG, REPORT_ROOT,
# RESULT_ROOT, svf_file.

# Keep SVF complete and hierarchy-friendly for Formality.
set_app_var hdlin_enable_hier_map true
set_app_var hdlin_auto_save_templates false
set hdlin_ignore_embedded_configuration true
set_svf $svf_file
set_verification_top
set fm_priority_designs [get_designs -quiet {FA_ROW_STATE_REAL FA_OACC_UPDATE_REAL GEMM_V3 FA_QK_PV_SHARED_CORE_REAL}]
if {[sizeof_collection $fm_priority_designs] > 0} {
    set_verification_priority -high $fm_priority_designs
}

# Memory guard: keep hierarchy, avoid broad ungrouping, and limit local host use.
set_host_options -max_cores 4
uniquify

# IO/constraint completeness reports before optimization changes the picture.
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_check_timing_precompile.rpt] { check_timing }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_ports_inputs_verbose.rpt] { report_port -verbose [all_inputs] }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_ports_outputs_verbose.rpt] { report_port -verbose [all_outputs] }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_clock_report.rpt] { report_clock -attributes }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_constraint_precompile.rpt] { report_constraint -all_violators -verbose }

# Constant/tie-net DRC cleanup before and after compile to reduce noisy netlist
# fanout and multiple-port-net artifacts without flattening RTL hierarchy.
set_fix_multiple_port_nets -all -buffer_constants [current_design]
compile_ultra -no_autoungroup
set_fix_multiple_port_nets -all -buffer_constants [current_design]

# Names and reports for readable netlist and debuggable DRC closure.
change_names -rules verilog -hierarchy
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_qor.rpt] { report_qor }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_area_hier.rpt] { report_area -hierarchy }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_timing_full_20.rpt] { report_timing -path full -delay max -nets -max_paths 20 -transition_time -capacitance }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_max_transition_violators.rpt] { report_constraint -all_violators -verbose -max_transition }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_max_cap_violators.rpt] { report_constraint -all_violators -verbose -max_capacitance }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_check_design_postcompile.rpt] { check_design }
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_reference_postcompile.rpt] { report_reference }

write_sdc -nosplit [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}.sdc]
write -hierarchy -format ddc -output [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}.ddc]
write_file -format verilog -hierarchy -output [file join $RESULT_ROOT ${ACTIVE_TOP}_${RUN_TAG}.v]
set_svf -off
