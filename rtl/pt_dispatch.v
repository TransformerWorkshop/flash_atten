`include "param.vh"

module PT_DISPATCH #(
	parameter GEMM_X_DIM = 4,
	parameter GEMM_Y_DIM = 4,
	parameter LUT_DEPTH  = 8
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,

	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst,
	input  wire [31:0]                ctrl_id,

	output wire                       mem_cmd_valid,
	input  wire                       mem_cmd_ready,
	output wire [`PT_MEM_KIND_W-1:0]  mem_cmd_kind,
	output wire [`INST_WIDTH-1:0]     mem_cmd_inst,
	output wire [31:0]                mem_cmd_id,
	output wire [15:0]                mem_cmd_seq,

	output wire                       miss_req_valid,
	input  wire                       miss_req_ready,
	output wire [31:0]                miss_req_id,
	output wire [9:0]                 miss_req_a_off,
	output wire [9:0]                 miss_req_b_off,
	output wire                       miss_req_need_a,
	output wire                       miss_req_need_b,

	input  wire                       mem_done_valid,
	input  wire [31:0]                mem_done_id,
	input  wire [15:0]                mem_done_seq,
	input  wire                       mem_done_err,
	input  wire                       load_done_valid,
	input  wire [31:0]                load_done_id,
	input  wire                       load_done_side,
	input  wire                       load_done_buf,
	input  wire [9:0]                 load_done_local_off,
	input  wire [9:0]                 load_done_ext_off,
	input  wire                       miss_done_valid,
	input  wire [31:0]                miss_done_id,
	input  wire                       miss_done_err,
	input  wire                       ce_issue_ok,

	output wire                       ce_inst_valid,
	input  wire                       ce_inst_ready,
	output wire [`INST_WIDTH-1:0]     ce_inst,
	output wire [31:0]                ce_id
);

	localparam integer A_DIM_CONST = (GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM;
	localparam integer B_DIM_CONST = (GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM;
	localparam integer A_DIM_SHIFT = $clog2(A_DIM_CONST);
	localparam integer B_DIM_SHIFT = $clog2(B_DIM_CONST);
	localparam integer LUT_AW      = (LUT_DEPTH <= 1) ? 1 : $clog2(LUT_DEPTH);
	localparam integer MAX_DIM     = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer QCFG_CNT_W  = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM + 1);
	localparam integer MEMQ_W      = `PT_MEM_KIND_W + `INST_WIDTH + 32 + 16 + 16;
	localparam integer COMPQ_W     = 4 + `INST_WIDTH + 32 + 16;
	localparam integer CEQ_W       = `INST_WIDTH + 32 + 16;

	localparam LOAD_SIDE_A = 1'b0;
	localparam LOAD_SIDE_B = 1'b1;

	wire [3:0] ctrl_opcode = ctrl_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
	wire [1:0] ctrl_m      = ctrl_inst[`PT_INST_M_H:`PT_INST_M_L];
	wire [1:0] ctrl_n      = ctrl_inst[`PT_INST_N_H:`PT_INST_N_L];
	wire [1:0] ctrl_k      = ctrl_inst[`PT_INST_K_H:`PT_INST_K_L];
	wire [9:0] ctrl_a_off  = ctrl_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] ctrl_b_off  = ctrl_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
	wire [5:0] ctrl_reserved_hi = ctrl_inst[27:22];
	wire [1:0] ctrl_reserved_lo = ctrl_inst[1:0];
	wire ctrl_qcfg_hdr_cmd = (ctrl_inst[`PT_QCFG_CMD_H:`PT_QCFG_CMD_L] == `PT_QCFG_CMD_HDR);
	wire [1:0] ctrl_qcfg_qtype = ctrl_inst[`PT_QCFG_QTYPE_H:`PT_QCFG_QTYPE_L];
	wire [2:0] ctrl_qcfg_gran  = ctrl_inst[`PT_QCFG_GRAN_H:`PT_QCFG_GRAN_L];
	wire ctrl_load_need_a = ctrl_inst[`PT_LOAD_NEED_A_BIT];
	wire ctrl_load_need_b = ctrl_inst[`PT_LOAD_NEED_B_BIT];
	wire [3:0] ctrl_load_reserved_hi = ctrl_inst[`PT_LOAD_RSV_H:`PT_LOAD_RSV_L];

	localparam [7:0] A_DIM_MASK_8 = A_DIM_CONST - 1;
	localparam [7:0] B_DIM_MASK_8 = B_DIM_CONST - 1;

	wire ctrl_mnk_is_full = (ctrl_m == `PT_SCALE_FULL) &&
	                        (ctrl_n == `PT_SCALE_FULL) &&
	                        (ctrl_k == `PT_SCALE_FULL);
	wire ctrl_a_row_aligned = ((ctrl_a_off[7:0] & A_DIM_MASK_8) == 8'd0);
	wire ctrl_b_row_aligned = ((ctrl_b_off[7:0] & B_DIM_MASK_8) == 8'd0);
	wire ctrl_matadd_reserved_zero = (ctrl_reserved_hi == 6'd0) && (ctrl_reserved_lo == 2'b00);
	wire ctrl_matadd_legal = ctrl_a_off[9] &&
	                         !ctrl_b_off[9] &&
	                         ctrl_b_row_aligned &&
	                         ctrl_matadd_reserved_zero;
	wire ctrl_load_reserved_zero = (ctrl_load_reserved_hi == 4'd0) && (ctrl_reserved_lo == 2'b00);
	wire ctrl_load_legal = (ctrl_load_need_a || ctrl_load_need_b) &&
	                       ctrl_load_reserved_zero &&
	                       (!ctrl_load_need_a || (!ctrl_a_off[9] && ctrl_a_row_aligned)) &&
	                       (!ctrl_load_need_b || (!ctrl_b_off[9] && ctrl_b_row_aligned));

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

	reg                         qcfg_capture_active;
	reg [QCFG_CNT_W-1:0]        qcfg_capture_rem;
	reg [15:0]                  qcfg_capture_end_seq;
	reg [15:0]                  next_accept_seq;

	reg                         ingress_to_mem;
	reg [`PT_MEM_KIND_W-1:0]    ingress_mem_kind;
	reg [15:0]                  ingress_aux_seq;
	reg                         ingress_to_compute;
	reg [3:0]                   ingress_comp_kind;
	wire [15:0] qcfg_session_end_seq = next_accept_seq + {{(16-QCFG_CNT_W){1'b0}}, qcfg_hdr_cnt};

	always @(*) begin
		ingress_to_mem     = 1'b1;
		ingress_mem_kind   = `PT_MEM_KIND_REJECT;
		ingress_aux_seq    = 16'd0;
		ingress_to_compute = 1'b0;
		ingress_comp_kind  = ctrl_opcode;
		if (qcfg_capture_active) begin
			ingress_mem_kind = `PT_MEM_KIND_QCFG_PAYLOAD;
			ingress_aux_seq  = qcfg_capture_end_seq;
		end else begin
			case (ctrl_opcode)
				`PT_OP_CFG: begin
					ingress_mem_kind = `PT_MEM_KIND_CFG;
				end
				`PT_OP_QCFG: begin
					if (qcfg_hdr_ok && !qcfg_hdr_err && (qcfg_hdr_cnt != {QCFG_CNT_W{1'b0}})) begin
						ingress_mem_kind = `PT_MEM_KIND_QCFG_HDR;
						ingress_aux_seq  = qcfg_session_end_seq;
					end else begin
						ingress_mem_kind = `PT_MEM_KIND_REJECT;
					end
				end
				`PT_OP_LOAD: begin
					ingress_mem_kind = ctrl_load_legal ? `PT_MEM_KIND_LOAD : `PT_MEM_KIND_REJECT;
				end
				`PT_OP_MATMUL: begin
					if (ctrl_mnk_is_full && ctrl_a_row_aligned && ctrl_b_row_aligned) begin
						ingress_to_mem     = 1'b0;
						ingress_to_compute = 1'b1;
					end else begin
						ingress_mem_kind = `PT_MEM_KIND_REJECT;
					end
				end
				`PT_OP_MATADD: begin
					if (ctrl_matadd_legal) begin
						ingress_to_mem     = 1'b0;
						ingress_to_compute = 1'b1;
					end else begin
						ingress_mem_kind = `PT_MEM_KIND_REJECT;
					end
				end
				default: begin
					ingress_mem_kind = `PT_MEM_KIND_REJECT;
				end
			endcase
		end
	end

	wire [MEMQ_W-1:0] mem_q_in_data = {ingress_aux_seq, next_accept_seq, ctrl_id, ctrl_inst, ingress_mem_kind};
	wire [COMPQ_W-1:0] comp_q_in_data = {next_accept_seq, ctrl_id, ctrl_inst, ingress_comp_kind};
	wire               mem_q_in_ready;
	wire               comp_q_in_ready;
	wire [MEMQ_W-1:0]  mem_q_out_data;
	wire               mem_q_out_valid;
	wire               mem_q_out_ready;
	wire [COMPQ_W-1:0] comp_q_out_data;
	wire               comp_q_out_valid;
	wire               comp_q_out_ready;

	sync_fifo #(
		.WIDTH(MEMQ_W),
		.DEPTH(`QUEUE_LEN)
	) mem_queue (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (clear),
		.data_in  (mem_q_in_data),
		.valid_in (ctrl_valid && ingress_to_mem),
		.ready_in (mem_q_in_ready),
		.data_out (mem_q_out_data),
		.valid_out(mem_q_out_valid),
		.ready_out(mem_q_out_ready)
	);

	sync_fifo #(
		.WIDTH(COMPQ_W),
		.DEPTH(`QUEUE_LEN)
	) compute_queue (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (clear),
		.data_in  (comp_q_in_data),
		.valid_in (ctrl_valid && ingress_to_compute),
		.ready_in (comp_q_in_ready),
		.data_out (comp_q_out_data),
		.valid_out(comp_q_out_valid),
		.ready_out(comp_q_out_ready)
	);

	assign ctrl_ready = qcfg_capture_active ? mem_q_in_ready :
	                    (ingress_to_compute ? comp_q_in_ready : mem_q_in_ready);

	wire [`PT_MEM_KIND_W-1:0] mem_q_kind = mem_q_out_data[`PT_MEM_KIND_W-1:0];
	wire [`INST_WIDTH-1:0]    mem_q_inst = mem_q_out_data[`PT_MEM_KIND_W+`INST_WIDTH-1:`PT_MEM_KIND_W];
	wire [31:0]               mem_q_id   = mem_q_out_data[`PT_MEM_KIND_W+`INST_WIDTH+32-1:`PT_MEM_KIND_W+`INST_WIDTH];
	wire [15:0]               mem_q_seq  = mem_q_out_data[`PT_MEM_KIND_W+`INST_WIDTH+32+16-1:`PT_MEM_KIND_W+`INST_WIDTH+32];
	wire [15:0]               mem_q_aux  = mem_q_out_data[MEMQ_W-1:`PT_MEM_KIND_W+`INST_WIDTH+32+16];

	wire [3:0]                comp_q_kind = comp_q_out_data[3:0];
	wire [`INST_WIDTH-1:0]    comp_q_inst = comp_q_out_data[4+`INST_WIDTH-1:4];
	wire [31:0]               comp_q_id   = comp_q_out_data[4+`INST_WIDTH+32-1:4+`INST_WIDTH];
	wire [15:0]               comp_q_seq  = comp_q_out_data[COMPQ_W-1:4+`INST_WIDTH+32];

	reg              lut_valid     [0:LUT_DEPTH-1];
	reg [31:0]       lut_id        [0:LUT_DEPTH-1];
	reg              lut_a_valid   [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_loc_off [0:LUT_DEPTH-1];
	reg              lut_b_valid   [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_loc_off [0:LUT_DEPTH-1];
	reg [LUT_AW-1:0] lut_alloc_ptr;

	reg              comp_lut_found;
	reg [LUT_AW-1:0] comp_lut_idx;
	reg              comp_a_hit;
	reg              comp_b_hit;
	reg [9:0]        comp_a_local_off;
	reg [9:0]        comp_b_local_off;

	reg              load_lut_found;
	reg [LUT_AW-1:0] load_lut_idx;

	wire comp_a_is_m = comp_q_inst[`PT_INST_A_OFF_H];
	wire comp_b_is_m = comp_q_inst[`PT_INST_B_OFF_H];
	wire [9:0] comp_a_off = comp_q_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] comp_b_off = comp_q_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];

	integer li;
	always @(*) begin
		comp_lut_found   = 1'b0;
		comp_lut_idx     = {LUT_AW{1'b0}};
		comp_a_hit       = comp_a_is_m;
		comp_b_hit       = comp_b_is_m;
		comp_a_local_off = comp_a_off;
		comp_b_local_off = comp_b_off;
		for (li = 0; li < LUT_DEPTH; li = li + 1) begin
			if (!comp_lut_found && lut_valid[li] && (lut_id[li] == comp_q_id)) begin
				comp_lut_found = 1'b1;
				comp_lut_idx   = li[LUT_AW-1:0];
			end
		end
		if (comp_lut_found) begin
			if (!comp_a_is_m && lut_a_valid[comp_lut_idx] &&
			    ((comp_a_off == lut_a_ext_off[comp_lut_idx]) ||
			     (comp_a_off == lut_a_loc_off[comp_lut_idx]))) begin
				comp_a_hit       = 1'b1;
				comp_a_local_off = lut_a_loc_off[comp_lut_idx];
			end
			if (!comp_b_is_m && lut_b_valid[comp_lut_idx] &&
			    ((comp_b_off == lut_b_ext_off[comp_lut_idx]) ||
			     (comp_b_off == lut_b_loc_off[comp_lut_idx]))) begin
				comp_b_hit       = 1'b1;
				comp_b_local_off = lut_b_loc_off[comp_lut_idx];
			end
		end
	end

	integer lj;
	always @(*) begin
		load_lut_found = 1'b0;
		load_lut_idx   = {LUT_AW{1'b0}};
		for (lj = 0; lj < LUT_DEPTH; lj = lj + 1) begin
			if (!load_lut_found && lut_valid[lj] && (lut_id[lj] == load_done_id)) begin
				load_lut_found = 1'b1;
				load_lut_idx   = lj[LUT_AW-1:0];
			end
		end
	end

	wire comp_seq_match = comp_q_out_valid && (comp_q_seq == next_issue_seq);
	wire comp_need_a    = comp_seq_match && !comp_a_hit;
	wire comp_need_b    = comp_seq_match && !comp_b_hit;
	wire comp_all_hit   = comp_seq_match && !comp_need_a && !comp_need_b;

	reg pending_compute_valid;
	reg [31:0] pending_compute_id;
	reg [15:0] pending_compute_seq;

	assign miss_req_valid  = !qcfg_barrier_active && comp_seq_match && !pending_compute_valid && (comp_need_a || comp_need_b);
	assign miss_req_id     = comp_q_id;
	assign miss_req_a_off  = comp_a_off;
	assign miss_req_b_off  = comp_b_off;
	assign miss_req_need_a = comp_need_a;
	assign miss_req_need_b = comp_need_b;
	wire miss_req_fire = miss_req_valid && miss_req_ready;

	reg [`INST_WIDTH-1:0] patched_comp_inst;
	always @(*) begin
		patched_comp_inst = comp_q_inst;
		if (!comp_a_is_m) begin
			patched_comp_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = comp_a_local_off;
		end
		if (!comp_b_is_m) begin
			patched_comp_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = comp_b_local_off;
		end
	end

	wire [CEQ_W-1:0] ce_q_in_data = {comp_q_seq, comp_q_id, patched_comp_inst};
	wire [CEQ_W-1:0] ce_q_out_data;
	wire             ce_q_in_ready;
	wire             ce_q_out_valid;
	wire             ce_q_out_ready;
	wire [`INST_WIDTH-1:0] ce_q_out_inst = ce_q_out_data[`INST_WIDTH-1:0];
	wire [31:0]            ce_q_out_id   = ce_q_out_data[`INST_WIDTH+32-1:`INST_WIDTH];
	wire [15:0]            ce_q_out_seq  = ce_q_out_data[CEQ_W-1:`INST_WIDTH+32];
	wire                   ce_q_enq_valid = !qcfg_barrier_active && comp_all_hit && !pending_compute_valid;
	wire                   ce_q_enq_fire = ce_q_enq_valid && ce_q_in_ready;
	wire                   ce_issue_fire = ce_q_out_valid && ce_issue_ok && ce_inst_ready;

	assign ce_inst_valid = ce_q_out_valid && ce_issue_ok;
	assign ce_inst       = ce_q_out_inst;
	assign ce_id         = ce_q_out_id;
	assign ce_q_out_ready = ce_issue_ok && ce_inst_ready;

	sync_fifo #(
		.WIDTH(CEQ_W),
		.DEPTH(`QUEUE_LEN)
	) ce_queue (
		.clk      (clk),
		.resetn   (rstn),
		.clear    (clear),
		.data_in  (ce_q_in_data),
		.valid_in (ce_q_enq_valid),
		.ready_in (ce_q_in_ready),
		.data_out (ce_q_out_data),
		.valid_out(ce_q_out_valid),
		.ready_out(ce_q_out_ready)
	);

	reg        qcfg_barrier_active;
	reg [15:0] qcfg_barrier_end_seq;
	reg        qcfg_drop_active;
	reg [15:0] qcfg_drop_end_seq;
	reg [15:0] next_issue_seq;

	wire drop_qcfg_payload = qcfg_drop_active &&
	                         mem_q_out_valid &&
	                         (mem_q_kind == `PT_MEM_KIND_QCFG_PAYLOAD) &&
	                         (mem_q_aux == qcfg_drop_end_seq);
	wire issue_mem_seq = mem_q_out_valid &&
	                     !qcfg_barrier_active &&
	                     (mem_q_seq == next_issue_seq) &&
	                     (mem_q_kind != `PT_MEM_KIND_QCFG_PAYLOAD);
	wire issue_qcfg_payload = mem_q_out_valid &&
	                          qcfg_barrier_active &&
	                          (mem_q_kind == `PT_MEM_KIND_QCFG_PAYLOAD) &&
	                          (mem_q_aux == qcfg_barrier_end_seq);
	assign mem_cmd_valid = !drop_qcfg_payload && (issue_mem_seq || issue_qcfg_payload);
	assign mem_cmd_kind  = mem_q_kind;
	assign mem_cmd_inst  = mem_q_inst;
	assign mem_cmd_id    = mem_q_id;
	assign mem_cmd_seq   = mem_q_seq;
	wire issue_mem_fire  = mem_cmd_valid && mem_cmd_ready;

	wire miss_err_consume = miss_done_valid &&
	                        pending_compute_valid &&
	                        miss_done_err &&
	                        comp_q_out_valid &&
	                        (comp_q_id == pending_compute_id) &&
	                        (comp_q_seq == pending_compute_seq);
	assign comp_q_out_ready = ce_q_enq_fire || miss_err_consume;
	assign mem_q_out_ready  = issue_mem_fire || drop_qcfg_payload;

	integer ri;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			qcfg_capture_active <= 1'b0;
			qcfg_capture_rem    <= {QCFG_CNT_W{1'b0}};
			qcfg_capture_end_seq <= 16'd0;
			next_accept_seq     <= 16'd0;
			qcfg_barrier_active <= 1'b0;
			qcfg_barrier_end_seq <= 16'd0;
			qcfg_drop_active    <= 1'b0;
			qcfg_drop_end_seq   <= 16'd0;
			next_issue_seq      <= 16'd0;
			pending_compute_valid <= 1'b0;
			pending_compute_id  <= 32'd0;
			pending_compute_seq <= 16'd0;
			lut_alloc_ptr       <= {LUT_AW{1'b0}};
			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
		end else if (clear) begin
			qcfg_capture_active <= 1'b0;
			qcfg_capture_rem    <= {QCFG_CNT_W{1'b0}};
			qcfg_capture_end_seq <= 16'd0;
			next_accept_seq     <= 16'd0;
			qcfg_barrier_active <= 1'b0;
			qcfg_barrier_end_seq <= 16'd0;
			qcfg_drop_active    <= 1'b0;
			qcfg_drop_end_seq   <= 16'd0;
			next_issue_seq      <= 16'd0;
			pending_compute_valid <= 1'b0;
			pending_compute_id  <= 32'd0;
			pending_compute_seq <= 16'd0;
			lut_alloc_ptr       <= {LUT_AW{1'b0}};
			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
		end else begin
			if (ctrl_valid && ctrl_ready) begin
				next_accept_seq <= next_accept_seq + 1'b1;
				if (qcfg_capture_active) begin
					if (qcfg_capture_rem == {{(QCFG_CNT_W-1){1'b0}}, 1'b1}) begin
						qcfg_capture_active <= 1'b0;
						qcfg_capture_rem    <= {QCFG_CNT_W{1'b0}};
						qcfg_capture_end_seq <= 16'd0;
					end else begin
						qcfg_capture_rem <= qcfg_capture_rem - 1'b1;
					end
				end else if ((ctrl_opcode == `PT_OP_QCFG) &&
				             qcfg_hdr_ok &&
				             !qcfg_hdr_err &&
				             (qcfg_hdr_cnt != {QCFG_CNT_W{1'b0}}) &&
				             ingress_to_mem &&
				             (ingress_mem_kind == `PT_MEM_KIND_QCFG_HDR)) begin
					qcfg_capture_active <= 1'b1;
					qcfg_capture_rem    <= qcfg_hdr_cnt;
					qcfg_capture_end_seq <= qcfg_session_end_seq;
				end
			end

			if (load_done_valid) begin
				if (!load_lut_found) begin
					lut_valid[lut_alloc_ptr]   <= 1'b1;
					lut_id[lut_alloc_ptr]      <= load_done_id;
					lut_a_valid[lut_alloc_ptr] <= 1'b0;
					lut_b_valid[lut_alloc_ptr] <= 1'b0;
					if (load_done_side == LOAD_SIDE_A) begin
						lut_a_valid[lut_alloc_ptr]   <= 1'b1;
						lut_a_ext_off[lut_alloc_ptr] <= load_done_ext_off;
						lut_a_loc_off[lut_alloc_ptr] <= load_done_local_off;
					end else begin
						lut_b_valid[lut_alloc_ptr]   <= 1'b1;
						lut_b_ext_off[lut_alloc_ptr] <= load_done_ext_off;
						lut_b_loc_off[lut_alloc_ptr] <= load_done_local_off;
					end
					lut_alloc_ptr <= lut_alloc_ptr + 1'b1;
				end else if (load_done_side == LOAD_SIDE_A) begin
					lut_a_valid[load_lut_idx]   <= 1'b1;
					lut_a_ext_off[load_lut_idx] <= load_done_ext_off;
					lut_a_loc_off[load_lut_idx] <= load_done_local_off;
				end else begin
					lut_b_valid[load_lut_idx]   <= 1'b1;
					lut_b_ext_off[load_lut_idx] <= load_done_ext_off;
					lut_b_loc_off[load_lut_idx] <= load_done_local_off;
				end
			end

			if (miss_req_fire) begin
				pending_compute_valid <= 1'b1;
				pending_compute_id    <= comp_q_id;
				pending_compute_seq   <= comp_q_seq;
			end

			if (issue_mem_fire && (mem_q_kind == `PT_MEM_KIND_QCFG_HDR)) begin
				qcfg_barrier_active  <= 1'b1;
				qcfg_barrier_end_seq <= mem_q_aux;
			end

			if (drop_qcfg_payload && (mem_q_seq == qcfg_drop_end_seq)) begin
				qcfg_drop_active  <= 1'b0;
				qcfg_drop_end_seq <= 16'd0;
			end else if (qcfg_drop_active &&
			             (!mem_q_out_valid ||
			              (mem_q_kind != `PT_MEM_KIND_QCFG_PAYLOAD) ||
			              (mem_q_aux != qcfg_drop_end_seq))) begin
				qcfg_drop_active  <= 1'b0;
				qcfg_drop_end_seq <= 16'd0;
			end

			if (miss_done_valid && pending_compute_valid && (miss_done_id == pending_compute_id)) begin
				pending_compute_valid <= 1'b0;
				if (miss_done_err && (pending_compute_seq == next_issue_seq)) begin
					next_issue_seq <= next_issue_seq + 1'b1;
				end
			end

			if (mem_done_valid) begin
				if (qcfg_barrier_active) begin
					next_issue_seq     <= qcfg_barrier_end_seq + 1'b1;
					qcfg_barrier_active <= 1'b0;
					if (mem_done_err && (mem_done_seq != qcfg_barrier_end_seq)) begin
						qcfg_drop_active  <= 1'b1;
						qcfg_drop_end_seq <= qcfg_barrier_end_seq;
					end
				end else if (mem_done_seq == next_issue_seq) begin
					next_issue_seq <= next_issue_seq + 1'b1;
				end
			end

			if (ce_issue_fire && (ce_q_out_seq == next_issue_seq)) begin
				next_issue_seq <= next_issue_seq + 1'b1;
			end
		end
	end

	wire _unused_ok = &{1'b0, mem_done_id[0], load_done_buf};

endmodule
