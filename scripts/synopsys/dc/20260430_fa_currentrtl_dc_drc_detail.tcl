set PROJECT_ROOT [file normalize [file join [file dirname [info script]] ../../..]]
source [file join $PROJECT_ROOT synopsys dc flow setup.tcl]

set ACTIVE_TOP FA_TOP_BASELINE
set REPORT_ROOT [file join $TOOL_ROOT $REPORTS_SUBDIR $ACTIVE_TOP]
set RESULT_ROOT [file join $TOOL_ROOT $RESULTS_SUBDIR $ACTIVE_TOP]
set DDC_FILE [file join $RESULT_ROOT ${ACTIVE_TOP}_compile.ddc]
set RUN_TAG 20260430_1710_currentrtl
file mkdir $REPORT_ROOT

if {![file exists $DDC_FILE]} {
    puts "Missing compiled DDC: $DDC_FILE"
    exit 1
}

dc_note "Read compiled DDC for DRC detail: $DDC_FILE"
read_ddc $DDC_FILE
current_design $ACTIVE_TOP
link
source [file join $CONSTRAINTS_ROOT base.sdc]

redirect -file [file join $REPORT_ROOT ${RUN_TAG}_constraint_summary.rpt] {
    report_constraint -all_violators
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_max_transition_violators.rpt] {
    report_constraint -max_transition -all_violators -verbose
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_max_cap_violators.rpt] {
    report_constraint -max_capacitance -all_violators -verbose
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_timing_20.rpt] {
    report_timing -max_paths 20 -transition_time -capacitance -nets
}
redirect -file [file join $REPORT_ROOT ${RUN_TAG}_qor.rpt] {
    report_qor
}

set violator_file [open [file join $REPORT_ROOT ${RUN_TAG}_max_transition_nets.tsv] w]
puts $violator_file "net\tfull_name\tmax_transition\ttransition\tslack\tfanout"
set violator_nets [get_nets -hierarchical -quiet -filter "max_transition < transition"]
foreach_in_collection net $violator_nets {
    set net_name [get_object_name $net]
    set full_name [get_attribute -quiet $net full_name]
    if {$full_name eq ""} {
        set full_name $net_name
    }
    set max_tran [get_attribute -quiet $net max_transition]
    set tran [get_attribute -quiet $net transition]
    set slack [expr {$max_tran eq "" || $tran eq "" ? "" : $max_tran - $tran}]
    set fanout [sizeof_collection [all_fanout -flat -from $net -endpoints_only]]
    puts $violator_file "$net_name\t$full_name\t$max_tran\t$tran\t$slack\t$fanout"
}
close $violator_file

set pins_file [open [file join $REPORT_ROOT ${RUN_TAG}_max_transition_pins.tsv] w]
puts $pins_file "pin\tpin_full_name\tcell\tref_name\tnet\tmax_transition\ttransition\tfanout"
set violator_pins [get_pins -hierarchical -quiet -filter "max_transition < transition"]
foreach_in_collection pin $violator_pins {
    set pin_name [get_object_name $pin]
    set pin_full_name [get_attribute -quiet $pin full_name]
    if {$pin_full_name eq ""} {
        set pin_full_name $pin_name
    }
    set cell [get_cells -quiet -of_objects $pin]
    set cell_name [get_object_name $cell]
    set ref_name [get_attribute -quiet $cell ref_name]
    set net [get_nets -quiet -of_objects $pin]
    set net_name [get_object_name $net]
    set max_tran [get_attribute -quiet $pin max_transition]
    set tran [get_attribute -quiet $pin transition]
    set fanout [expr {$net_name eq "" ? "" : [sizeof_collection [all_fanout -flat -from $net -endpoints_only]]}]
    puts $pins_file "$pin_name\t$pin_full_name\t$cell_name\t$ref_name\t$net_name\t$max_tran\t$tran\t$fanout"
}
close $pins_file

dc_note "DRC detail reports complete"
exit
