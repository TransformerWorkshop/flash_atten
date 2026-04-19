`include "param.vh"

module PT_DISPATCH #(
	parameter GEMM_X_DIM = 4,
	parameter GEMM_Y_DIM = 4
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst,
	input  wire [31:0]                ctrl_id,
	output wire                       md_cmd_valid,
	input  wire                       md_cmd_ready,
	output wire [`PT_MEM_KIND_W-1:0]  md_cmd_kind,
	output wire [`INST_WIDTH-1:0]     md_cmd_inst,
	output wire [31:0]                md_cmd_id,
	input  wire                       md_cmd_resp_valid,
	output wire                       malloc_cmd_valid,
	input  wire                       malloc_cmd_ready,
	output wire [`PT_MALLOC_KIND_W-1:0] malloc_cmd_kind,
	output wire [`INST_WIDTH-1:0]     malloc_cmd_inst,
	output wire [31:0]                malloc_cmd_id,
	input  wire                       malloc_resp_valid,
	input  wire                       malloc_exec_busy,
	input  wire                       malloc_serial_busy
);

	PT_DISPATCH_V2 #(
		.GEMM_X_DIM(GEMM_X_DIM),
		.GEMM_Y_DIM(GEMM_Y_DIM)
	) u_dispatch_v2 (
		.clk             (clk),
		.rstn            (rstn),
		.clear           (clear),
		.ctrl_valid      (ctrl_valid),
		.ctrl_ready      (ctrl_ready),
		.ctrl_inst       (ctrl_inst),
		.ctrl_id         (ctrl_id),
		.md_cmd_valid    (md_cmd_valid),
		.md_cmd_ready    (md_cmd_ready),
		.md_cmd_kind     (md_cmd_kind),
		.md_cmd_inst     (md_cmd_inst),
		.md_cmd_id       (md_cmd_id),
		.md_cmd_resp_valid(md_cmd_resp_valid),
		.malloc_cmd_valid(malloc_cmd_valid),
		.malloc_cmd_ready(malloc_cmd_ready),
		.malloc_cmd_kind (malloc_cmd_kind),
		.malloc_cmd_inst (malloc_cmd_inst),
		.malloc_cmd_id   (malloc_cmd_id),
		.malloc_resp_valid(malloc_resp_valid),
		.malloc_exec_busy(malloc_exec_busy),
		.malloc_serial_busy(malloc_serial_busy)
	);

endmodule
