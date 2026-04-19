`include "param.vh"

module PT_DISPATCH_V2 #(
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

	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer QCFG_CNT_W = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM + 1);
	localparam integer CMD_KIND_W = 1 + `PT_MEM_KIND_W + `PT_MALLOC_KIND_W;
	localparam integer CMDQ_W = CMD_KIND_W + `INST_WIDTH + 32;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_CFG          = 2'd0;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_QCFG_HDR     = 2'd1;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_QCFG_PAYLOAD = 2'd2;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_REJECT       = 2'd3;
	localparam [1:0] ACTIVE_NONE = 2'd0;
	localparam [1:0] ACTIVE_MD   = 2'd1;
	wire dispatch_unused_inputs = malloc_resp_valid;

	wire [3:0] ctrl_opcode = ctrl_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
	wire [3:0] ctrl_matmul_m_tiles = ctrl_inst[`PT_MATMUL_M_TILES_H:`PT_MATMUL_M_TILES_L];
	wire [3:0] ctrl_matmul_n_tiles = ctrl_inst[`PT_MATMUL_N_TILES_H:`PT_MATMUL_N_TILES_L];
	wire [3:0] ctrl_matmul_k_tiles = ctrl_inst[`PT_MATMUL_K_TILES_H:`PT_MATMUL_K_TILES_L];
	wire [7:0] ctrl_matmul_reserved_a = ctrl_inst[`PT_MATMUL_RESERVED_A_H:`PT_MATMUL_RESERVED_A_L];
	wire [7:0] ctrl_matmul_reserved_b = ctrl_inst[`PT_MATMUL_RESERVED_B_H:`PT_MATMUL_RESERVED_B_L];
	wire [5:0] ctrl_matadd_reserved_hi = ctrl_inst[`PT_MATADD_RESERVED_HI_H:`PT_MATADD_RESERVED_HI_L];
	wire [9:0] ctrl_matadd_m_off = ctrl_inst[`PT_MATADD_M_OFF_H:`PT_MATADD_M_OFF_L];
	wire [9:0] ctrl_matadd_c_field = ctrl_inst[`PT_MATADD_C_FIELD_H:`PT_MATADD_C_FIELD_L];
	wire [1:0] ctrl_matadd_reserved_lo = ctrl_inst[`PT_MATADD_RESERVED_LO_H:`PT_MATADD_RESERVED_LO_L];
	wire ctrl_load_need_a = ctrl_inst[`PT_LOAD_NEED_A_BIT];
	wire ctrl_load_need_b = ctrl_inst[`PT_LOAD_NEED_B_BIT];
	wire [`PT_SIZE_W-1:0] ctrl_load_a_size = ctrl_inst[`PT_LOAD_A_SIZE_H:`PT_LOAD_A_SIZE_L];
	wire [`PT_SIZE_W-1:0] ctrl_load_b_size = ctrl_inst[`PT_LOAD_B_SIZE_H:`PT_LOAD_B_SIZE_L];
	wire [5:0] ctrl_load_reserved = ctrl_inst[`PT_LOAD_RSV_H:`PT_LOAD_RSV_L];
	wire [1:0] ctrl_load_m_code = ctrl_inst[`PT_LOAD_M_CODE_H:`PT_LOAD_M_CODE_L];
	wire [1:0] ctrl_load_n_code = ctrl_inst[`PT_LOAD_N_CODE_H:`PT_LOAD_N_CODE_L];
	wire [1:0] ctrl_load_k_code = ctrl_inst[`PT_LOAD_K_CODE_H:`PT_LOAD_K_CODE_L];
	wire ctrl_qcfg_hdr_cmd = (ctrl_inst[`PT_QCFG_CMD_H:`PT_QCFG_CMD_L] == `PT_QCFG_CMD_HDR);
	wire [1:0] ctrl_qcfg_qtype = ctrl_inst[`PT_QCFG_QTYPE_H:`PT_QCFG_QTYPE_L];
	wire [2:0] ctrl_qcfg_gran = ctrl_inst[`PT_QCFG_GRAN_H:`PT_QCFG_GRAN_L];
	wire ctrl_matmul_m_valid = (ctrl_matmul_m_tiles == `PT_TILES_1) || (ctrl_matmul_m_tiles == `PT_TILES_2) || (ctrl_matmul_m_tiles == `PT_TILES_4);
	wire ctrl_matmul_n_valid = (ctrl_matmul_n_tiles == `PT_TILES_1) || (ctrl_matmul_n_tiles == `PT_TILES_2) || (ctrl_matmul_n_tiles == `PT_TILES_4);
	wire ctrl_matmul_k_valid = (ctrl_matmul_k_tiles == `PT_TILES_1) || (ctrl_matmul_k_tiles == `PT_TILES_2) || (ctrl_matmul_k_tiles == `PT_TILES_4);
	wire ctrl_load_shape_legal = (ctrl_load_m_code != 2'b11) &&
	                            (ctrl_load_n_code != 2'b11) &&
	                            (ctrl_load_k_code != 2'b11);

	wire ctrl_matmul_legal = (ctrl_opcode == `PT_OP_MATMUL) &&
	                         ctrl_matmul_m_valid &&
	                         ctrl_matmul_n_valid &&
	                         ctrl_matmul_k_valid &&
	                         (ctrl_matmul_reserved_a == 8'd0) &&
	                         (ctrl_matmul_reserved_b == 8'd0);
	wire ctrl_load_legal = (ctrl_opcode == `PT_OP_LOAD) &&
	                       (ctrl_load_need_a || ctrl_load_need_b) &&
	                       ctrl_load_shape_legal &&
	                       (!ctrl_load_need_a || (ctrl_load_a_size != {`PT_SIZE_W{1'b0}})) &&
	                       (!ctrl_load_need_b || (ctrl_load_b_size != {`PT_SIZE_W{1'b0}}));
	wire ctrl_matadd_legal = (ctrl_opcode == `PT_OP_MATADD) &&
	                         (ctrl_matadd_reserved_hi == 6'd0) &&
	                         (ctrl_matadd_reserved_lo == 2'b00) &&
	                         (ctrl_matadd_c_field == 10'd0) &&
	                         ctrl_matadd_m_off[9] &&
	                         (ctrl_matadd_m_off[7:0] == 8'd0);

	reg qcfg_hdr_ok;
	reg qcfg_hdr_err;
	reg [QCFG_CNT_W-1:0] qcfg_hdr_cnt;
	always @(*) begin
		qcfg_hdr_ok  = 1'b0;
		qcfg_hdr_err = 1'b0;
		qcfg_hdr_cnt = {QCFG_CNT_W{1'b0}};
		if (ctrl_qcfg_hdr_cmd && (ctrl_qcfg_qtype == `PT_QTYPE_SYMMETRIC)) begin
			case (ctrl_qcfg_gran)
				`PT_QGRAN_PER_TENSOR: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = {{(QCFG_CNT_W-1){1'b0}}, 1'b1};
				end
				`PT_QGRAN_X_WISE: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = GEMM_X_DIM[QCFG_CNT_W-1:0];
				end
				`PT_QGRAN_Y_WISE: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = GEMM_Y_DIM[QCFG_CNT_W-1:0];
				end
				`PT_QGRAN_X_WISE_DIV2: begin
					if ((GEMM_X_DIM % 2) == 0) begin
						qcfg_hdr_ok  = 1'b1;
						qcfg_hdr_cnt = (GEMM_X_DIM >> 1);
					end else begin
						qcfg_hdr_err = 1'b1;
					end
				end
				`PT_QGRAN_Y_WISE_DIV2: begin
					if ((GEMM_Y_DIM % 2) == 0) begin
						qcfg_hdr_ok  = 1'b1;
						qcfg_hdr_cnt = (GEMM_Y_DIM >> 1);
					end else begin
						qcfg_hdr_err = 1'b1;
					end
				end
				default: begin
					qcfg_hdr_err = 1'b1;
				end
			endcase
		end else begin
			qcfg_hdr_err = 1'b1;
		end
	end

	reg qcfg_capture_active_r;
	reg [QCFG_CNT_W-1:0] qcfg_capture_rem_r;
	reg ingress_is_md;
	reg [`PT_MEM_KIND_W-1:0] ingress_md_kind;
	reg [`PT_MALLOC_KIND_W-1:0] ingress_malloc_kind;

	always @(*) begin
		ingress_is_md       = 1'b1;
		ingress_md_kind     = MEM_KIND_REJECT;
		ingress_malloc_kind = `PT_MALLOC_KIND_LOAD;
		if (qcfg_capture_active_r) begin
			ingress_is_md   = 1'b1;
			ingress_md_kind = MEM_KIND_QCFG_PAYLOAD;
		end else begin
			case (ctrl_opcode)
				`PT_OP_CFG: begin
					ingress_is_md   = 1'b1;
					ingress_md_kind = MEM_KIND_CFG;
				end
				`PT_OP_QCFG: begin
					ingress_is_md   = 1'b1;
					ingress_md_kind = (qcfg_hdr_ok && !qcfg_hdr_err && (qcfg_hdr_cnt != {QCFG_CNT_W{1'b0}})) ?
					                  MEM_KIND_QCFG_HDR : MEM_KIND_REJECT;
				end
				`PT_OP_LOAD: begin
					if (ctrl_load_legal) begin
						ingress_is_md       = 1'b0;
						ingress_malloc_kind = `PT_MALLOC_KIND_LOAD;
					end else begin
						ingress_is_md   = 1'b1;
						ingress_md_kind = MEM_KIND_REJECT;
					end
				end
				`PT_OP_MATMUL: begin
					if (ctrl_matmul_legal) begin
						ingress_is_md       = 1'b0;
						ingress_malloc_kind = `PT_MALLOC_KIND_MATMUL;
					end else begin
						ingress_is_md   = 1'b1;
						ingress_md_kind = MEM_KIND_REJECT;
					end
				end
				`PT_OP_MATADD: begin
					if (ctrl_matadd_legal) begin
						ingress_is_md       = 1'b0;
						ingress_malloc_kind = `PT_MALLOC_KIND_MATADD;
					end else begin
						ingress_is_md   = 1'b1;
						ingress_md_kind = MEM_KIND_REJECT;
					end
				end
				default: begin
					ingress_is_md   = 1'b1;
					ingress_md_kind = MEM_KIND_REJECT;
				end
			endcase
		end
	end

	wire [CMDQ_W-1:0] cmd_q_in_data = {ingress_is_md, ingress_md_kind, ingress_malloc_kind, ctrl_inst, ctrl_id};
	wire cmd_q_in_ready;
	wire [CMDQ_W-1:0] cmd_q_out_data;
	wire cmd_q_out_valid;
	wire cmd_q_out_ready;

	sync_fifo #(
		.WIDTH(CMDQ_W),
		.DEPTH(`QUEUE_LEN)
	) u_cmd_queue (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (clear),
		.data_in  (cmd_q_in_data),
		.valid_in (ctrl_valid),
		.ready_in (cmd_q_in_ready),
		.data_out (cmd_q_out_data),
		.valid_out(cmd_q_out_valid),
		.ready_out(cmd_q_out_ready)
	);

	assign ctrl_ready = cmd_q_in_ready;

	wire q_out_is_md = cmd_q_out_data[CMDQ_W-1];
	wire [`PT_MEM_KIND_W-1:0] q_out_md_kind =
		cmd_q_out_data[CMDQ_W-2 -: `PT_MEM_KIND_W];
	wire [`PT_MALLOC_KIND_W-1:0] q_out_malloc_kind =
		cmd_q_out_data[CMDQ_W-2-`PT_MEM_KIND_W -: `PT_MALLOC_KIND_W];
	wire [`INST_WIDTH-1:0] q_out_inst = cmd_q_out_data[32+`INST_WIDTH-1:32];
	wire [31:0] q_out_id = cmd_q_out_data[31:0];

	reg [1:0] active_dst_r;
	wire allow_md_issue = malloc_cmd_ready && !malloc_exec_busy;
	wire allow_malloc_issue = (active_dst_r == ACTIVE_NONE) &&
	                         malloc_cmd_ready &&
	                         ((q_out_malloc_kind == `PT_MALLOC_KIND_LOAD)   ? !malloc_exec_busy :
	                          (q_out_malloc_kind == `PT_MALLOC_KIND_MATMUL) ? !malloc_serial_busy :
	                                                                          !malloc_exec_busy);
	wire issue_md = cmd_q_out_valid && q_out_is_md && allow_md_issue && md_cmd_ready;
	wire issue_malloc = cmd_q_out_valid && !q_out_is_md && allow_malloc_issue && malloc_cmd_ready;

	assign md_cmd_valid = cmd_q_out_valid && q_out_is_md && allow_md_issue;
	assign md_cmd_kind  = q_out_md_kind;
	assign md_cmd_inst  = q_out_inst;
	assign md_cmd_id    = q_out_id;

	assign malloc_cmd_valid = cmd_q_out_valid && !q_out_is_md && allow_malloc_issue;
	assign malloc_cmd_kind  = q_out_malloc_kind;
	assign malloc_cmd_inst  = q_out_inst;
	assign malloc_cmd_id    = q_out_id;

	assign cmd_q_out_ready = issue_md || issue_malloc;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			qcfg_capture_active_r <= 1'b0;
			qcfg_capture_rem_r    <= {QCFG_CNT_W{1'b0}};
			active_dst_r          <= ACTIVE_NONE;
		end else if (clear) begin
			qcfg_capture_active_r <= 1'b0;
			qcfg_capture_rem_r    <= {QCFG_CNT_W{1'b0}};
			active_dst_r          <= ACTIVE_NONE;
		end else begin
			if (ctrl_valid && ctrl_ready) begin
				if (qcfg_capture_active_r) begin
					if (qcfg_capture_rem_r == {{(QCFG_CNT_W-1){1'b0}}, 1'b1}) begin
						qcfg_capture_active_r <= 1'b0;
						qcfg_capture_rem_r    <= {QCFG_CNT_W{1'b0}};
					end else begin
						qcfg_capture_rem_r <= qcfg_capture_rem_r - 1'b1;
					end
				end else if ((ctrl_opcode == `PT_OP_QCFG) &&
				             qcfg_hdr_ok &&
				             !qcfg_hdr_err &&
				             (qcfg_hdr_cnt != {QCFG_CNT_W{1'b0}})) begin
					qcfg_capture_active_r <= 1'b1;
					qcfg_capture_rem_r    <= qcfg_hdr_cnt;
				end
			end

			if (issue_md && (active_dst_r == ACTIVE_NONE)) begin
				active_dst_r <= ACTIVE_MD;
			end else if ((active_dst_r == ACTIVE_MD) && md_cmd_resp_valid) begin
				active_dst_r <= ACTIVE_NONE;
			end
		end
	end

endmodule
