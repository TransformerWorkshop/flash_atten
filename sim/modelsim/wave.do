onerror {resume}
quietly WaveActivateNextPane {} 0
quietly delete wave *

# tb_gemm (wrapper + base) interface
add wave -noupdate /tb_gemm/u_tb_gemm_base/clk
add wave -noupdate /tb_gemm/u_tb_gemm_base/rstn
add wave -noupdate /tb_gemm/u_tb_gemm_base/start
add wave -noupdate /tb_gemm/u_tb_gemm_base/clear
add wave -noupdate /tb_gemm/u_tb_gemm_base/num_acc
add wave -noupdate /tb_gemm/u_tb_gemm_base/a
add wave -noupdate /tb_gemm/u_tb_gemm_base/a_valid
add wave -noupdate /tb_gemm/u_tb_gemm_base/a_ready
add wave -noupdate /tb_gemm/u_tb_gemm_base/b
add wave -noupdate /tb_gemm/u_tb_gemm_base/b_valid
add wave -noupdate /tb_gemm/u_tb_gemm_base/b_ready
add wave -noupdate /tb_gemm/u_tb_gemm_base/m_group_data
add wave -noupdate /tb_gemm/u_tb_gemm_base/m_group_valid
add wave -noupdate /tb_gemm/u_tb_gemm_base/m_group_ready
add wave -noupdate /tb_gemm/u_tb_gemm_base/m_group_idx
add wave -noupdate /tb_gemm/u_tb_gemm_base/m_last
add wave -noupdate /tb_gemm/u_tb_gemm_base/errors

# DUT internals for grouped output debug
add wave -noupdate -divider DUT
add wave -noupdate /tb_gemm/u_tb_gemm_base/dut/state
add wave -noupdate /tb_gemm/u_tb_gemm_base/dut/stream_idx
add wave -noupdate /tb_gemm/u_tb_gemm_base/dut/collected
add wave -noupdate /tb_gemm/u_tb_gemm_base/dut/group_word

WaveRestoreCursors {{Cursor 1} {0 ps} 0}
quietly wave cursor active 0
configure wave -namecolwidth 150
configure wave -valuecolwidth 100
configure wave -justifyvalue left
configure wave -signalnamewidth 1
configure wave -snapdistance 10
configure wave -datasetprefix 0
configure wave -rowmargin 4
configure wave -childrowmargin 2
configure wave -gridoffset 0
configure wave -gridperiod 1
configure wave -griddelta 40
configure wave -timeline 0
configure wave -timelineunits ns
update
WaveRestoreZoom {0 ps} {1 ns}
