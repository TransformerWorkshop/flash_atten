`include "param.vh"

module CSR_BANK #(
	parameter DATA_WIDTH = 32,
	parameter GEMM_X_DIM = 4,
	parameter GEMM_Y_DIM = 4
) (
	input  wire clk,
	input  wire rstn,
	input  wire clear,

	// base-address CSR writes
	input  wire        a_base_lo_we,
	input  wire        a_base_hi_we,
	input  wire        b_base_lo_we,
	input  wire        b_base_hi_we,
	input  wire [15:0] cfg_wdata16,

	// quantization CSR writes
	input  wire                                   quant_commit_we,
	input  wire [2:0]                             quant_mode_wdata,
	input  wire [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] quant_inv_scale_wdata,

	// CSR outputs
	output reg  [31:0]                            pcsr_a_base,
	output reg  [31:0]                            pcsr_b_base,
	output reg  [2:0]                             quant_mode,
	output reg  [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] quant_inv_scale
);

	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			pcsr_a_base    <= 32'd0;
			pcsr_b_base    <= 32'd0;
			quant_mode     <= `PT_QGRAN_PER_TENSOR;
			quant_inv_scale <= {MAX_DIM{32'h0001_0000}};
		end else if (clear) begin
			pcsr_a_base    <= 32'd0;
			pcsr_b_base    <= 32'd0;
			quant_mode     <= `PT_QGRAN_PER_TENSOR;
			quant_inv_scale <= {MAX_DIM{32'h0001_0000}};
		end else begin
			if (a_base_lo_we) begin
				pcsr_a_base[15:0] <= cfg_wdata16;
			end
			if (a_base_hi_we) begin
				pcsr_a_base[31:16] <= cfg_wdata16;
			end
			if (b_base_lo_we) begin
				pcsr_b_base[15:0] <= cfg_wdata16;
			end
			if (b_base_hi_we) begin
				pcsr_b_base[31:16] <= cfg_wdata16;
			end
			if (quant_commit_we) begin
				quant_mode      <= quant_mode_wdata;
				quant_inv_scale <= quant_inv_scale_wdata;
			end
		end
	end

endmodule
