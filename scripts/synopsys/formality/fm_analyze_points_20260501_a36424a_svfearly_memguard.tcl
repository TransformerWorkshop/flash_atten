set PROJECT_ROOT /home/host/Desktop/flash_atten
set ACTIVE_TOP FA_TOP_BASELINE
set RUN_TAG 20260501_a36424a_svfearly_memguard
set ANALYZE_TAG ${RUN_TAG}_analyze_points
set REPORT_ROOT [file join $PROJECT_ROOT synopsys formality reports $ACTIVE_TOP]
set RESULT_ROOT [file join $PROJECT_ROOT synopsys formality results $ACTIVE_TOP]
set SESSION_FILE [file join $RESULT_ROOT ${RUN_TAG}_rtl_vs_netlist_fm_session.fss]

file mkdir $REPORT_ROOT
file mkdir $RESULT_ROOT

proc note {msg} {
    puts ""
    puts "==== $msg ===="
    puts ""
}

if {![file exists $SESSION_FILE]} {
    puts "Missing Formality session: $SESSION_FILE"
    exit 1
}

note "Restore saved Formality session"
restore_session $SESSION_FILE

note "Capture restored status"
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_restored_status.rpt] { report_status }
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_unverified_points.rpt] { report_unverified_points }

note "Analyze unverified points, low effort, limit 500"
analyze_points -unverified -effort low -limit 500
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_summary_low_limit500.rpt] { report_analysis_results -summary }
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_full_low_limit500.rpt] { report_analysis_results }

note "Analyze unverified points, low effort, limit 500, no_operator_svp"
analyze_points -unverified -effort low -limit 500 -no_operator_svp
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_summary_low_limit500_no_operator_svp.rpt] { report_analysis_results -summary }
redirect -file [file join $REPORT_ROOT ${ANALYZE_TAG}_full_low_limit500_no_operator_svp.rpt] { report_analysis_results }

note "Save analysis session"
save_session -replace [file join $RESULT_ROOT ${ANALYZE_TAG}_fm_session]
exit
