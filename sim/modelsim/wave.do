onerror {resume}
quietly WaveActivateNextPane {} 0
quietly delete wave *

# tb_gemu top-level interface
add wave -noupdate /tb_gemu/clk
add wave -noupdate /tb_gemu/rstn
add wave -noupdate /tb_gemu/start
add wave -noupdate /tb_gemu/clear
add wave -noupdate /tb_gemu/num_acc
add wave -noupdate /tb_gemu/a
add wave -noupdate /tb_gemu/a_valid
add wave -noupdate /tb_gemu/a_ready
add wave -noupdate /tb_gemu/b
add wave -noupdate /tb_gemu/b_valid
add wave -noupdate /tb_gemu/b_ready
add wave -noupdate /tb_gemu/m
add wave -noupdate /tb_gemu/m_valid
add wave -noupdate /tb_gemu/m_ready
add wave -noupdate /tb_gemu/errors

# DUT internals for debugging handshakes and accumulation
add wave -noupdate -divider DUT
add wave -noupdate /tb_gemu/dut/fifo_*
add wave -noupdate /tb_gemu/dut/is_*
add wave -noupdate /tb_gemu/dut/acc*
add wave -noupdate /tb_gemu/dut/*_state

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
