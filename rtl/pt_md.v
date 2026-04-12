`include "param.vh"

module PT_MD #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4 ,
	parameter GEMM_Y_DIM   = 4 ,
	parameter EXT_ADDR_W   = 32,
	parameter DMA_BEATS_W  = 16,
	parameter LUT_DEPTH    = 8 ,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	input  wire                       clk ,
	input  wire                       rstn,
	input  wire                       clear,

	// host control stream
	input  wire                       ctrl_valid,
	output wire                       ctrl_ready,
	input  wire [`INST_WIDTH-1:0]     ctrl_inst ,
	input  wire [               31:0] ctrl_id   ,
	output reg                        md_resp_valid,
	output reg  [               31:0] md_resp,

	// stream payload for DMA load
	input  wire                       s_axis_tvalid,
	input  wire [     DATA_WIDTH-1:0] s_axis_tdata ,
	input  wire [                1:0] s_axis_tuser ,
	output wire                       s_axis_tready,

	// dma request/response
	output wire                       dma_req_valid     ,
	input  wire                       dma_req_ready     ,
	output wire [                1:0] dma_req_tuser     ,
	output wire [               31:0] dma_req_id        ,
	output wire [         EXT_ADDR_W-1:0] dma_req_ext_addr  ,
	output wire [                9:0] dma_req_local_addr,
	output wire [        DMA_BEATS_W-1:0] dma_req_beats     ,
	input  wire                       dma_done          ,
	input  wire                       dma_error         ,

	// memory write path
	output reg                        a_mem_wr_en  ,
	output reg                        a_mem_wr_buf ,
	output reg  [((GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM))-1:0] a_mem_wr_lane ,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] a_mem_wr_addr ,
	output reg  [         DATA_WIDTH-1:0] a_mem_wr_data ,

	output reg                        b_mem_wr_en  ,
	output reg                        b_mem_wr_buf ,
	output reg  [((GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM))-1:0] b_mem_wr_lane ,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] b_mem_wr_addr ,
	output reg  [         DATA_WIDTH-1:0] b_mem_wr_data ,

	// issue queue output toward CE
	output wire                       ce_inst_valid,
	input  wire                       ce_inst_ready,
	output wire [`INST_WIDTH-1:0]     ce_inst      ,
	output wire [               31:0] ce_id        ,

	// CE completion feedback (for M export scheduling)
	input  wire                       ce_resp_valid,
	input  wire [               31:0] ce_resp,

	// M export DMA request/response
	output wire                       m_dma_req_valid,
	input  wire                       m_dma_req_ready,
	output wire [               31:0] m_dma_req_id,
	output wire                       m_dma_req_buf,
	output wire [        DMA_BEATS_W-1:0] m_dma_req_beats,
	input  wire                       m_dma_done,
	input  wire                       m_dma_error,

	// M export AXIS stream (PT as source)
	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [         DATA_WIDTH-1:0] m_axis_tdata,
	output wire [       DATA_WIDTH/8-1:0] m_axis_tstrb,
	output wire                       m_axis_tlast,
	output wire                       m_axis_tkeep,
	output wire                       m_axis_tid,
	output wire                       m_axis_tdest,
	output wire [                1:0] m_axis_tuser,

	// M memory export read port (into PT_M_MEM)
	output wire                       exp_rd_en,
	output wire                       exp_rd_buf,
	output wire [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] exp_rd_addr,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_rd_data,

	// CSR bank read ports
	input  wire [31:0]                pcsr_a_base,
	input  wire [31:0]                pcsr_b_base,
	input  wire [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale,

	// CSR bank write ports
	output reg                        csr_a_base_lo_we,
	output reg                        csr_a_base_hi_we,
	output reg                        csr_b_base_lo_we,
	output reg                        csr_b_base_hi_we,
	output reg  [15:0]                csr_cfg_wdata16,
	output reg                        csr_quant_commit_we,
	output reg  [2:0]                 csr_quant_mode_wdata,
	output reg  [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale_wdata,

	// irq (error only)
	output wire                       irq
);

	localparam [1:0] MATRIX_A = 2'b01;
	localparam [1:0] MATRIX_B = 2'b10;

	localparam integer IQ_WIDTH = `INST_WIDTH + 32;
	localparam integer A_ELEMS  = GEMM_X_DIM * GEMM_X_DIM;
	localparam integer B_ELEMS  = GEMM_Y_DIM * GEMM_Y_DIM;
	localparam integer A_LW     = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW     = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_AW     = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW     = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);
	localparam integer LUT_AW   = (LUT_DEPTH <= 1) ? 1 : $clog2(LUT_DEPTH);
	localparam integer MAX_DIM  = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer QCFG_CNT_W = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM + 1);
	localparam integer ELEM_SHIFT = (DATA_WIDTH <= 8) ? 0 : $clog2(DATA_WIDTH / 8);
	localparam integer A_DIM_CONST = (GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM;
	localparam integer B_DIM_CONST = (GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM;
	localparam integer A_DIM_SHIFT = $clog2(A_DIM_CONST);
	localparam integer B_DIM_SHIFT = $clog2(B_DIM_CONST);
	localparam [7:0] A_DIM_MASK_8 = A_DIM_CONST - 1;
	localparam [7:0] B_DIM_MASK_8 = B_DIM_CONST - 1;
	localparam [DMA_BEATS_W-1:0] A_DIM_MASK_DMA = A_DIM_CONST - 1;
	localparam [DMA_BEATS_W-1:0] B_DIM_MASK_DMA = B_DIM_CONST - 1;
	localparam integer EXP_BEATS = GEMM_X_DIM * GEMM_Y_DIM;

	localparam [2:0] ST_IDLE      = 3'd0;
	localparam [2:0] ST_LUT_CHECK = 3'd1;
	localparam [2:0] ST_DMA_REQ   = 3'd2;
	localparam [2:0] ST_DMA_RECV  = 3'd3;
	localparam [2:0] ST_ENQ_CE    = 3'd4;
	localparam [2:0] ST_QCFG_LOAD = 3'd5;

	localparam [1:0] MBUF_FREE      = 2'd0;
	localparam [1:0] MBUF_READY     = 2'd1;
	localparam [1:0] MBUF_EXPORTING = 2'd2;

	localparam [1:0] EXP_IDLE      = 2'd0;
	localparam [1:0] EXP_REQ       = 2'd1;
	localparam [1:0] EXP_STREAM    = 2'd2;
	localparam [1:0] EXP_WAIT_DONE = 2'd3;

	reg [2:0] state;
	reg [2:0] next_state;

	function is_pow2;
		input integer value;
		begin
			is_pow2 = (value > 0) ? (((value & (value - 1)) == 0) ? 1'b1 : 1'b0) : 1'b0;
		end
	endfunction

	initial begin
		if (!is_pow2(GEMM_X_DIM) || !is_pow2(GEMM_Y_DIM)) begin
			$fatal(1, "PT_MD requires power-of-two GEMM_X_DIM/GEMM_Y_DIM, got %0d x %0d", GEMM_X_DIM, GEMM_Y_DIM);
		end
	end

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	function [9:0] make_a_local_off;
		input buf_sel;
		input [7:0] row_idx;
		begin
			make_a_local_off = {1'b0, buf_sel, row_to_a_elem(row_idx)};
		end
	endfunction

	function [9:0] make_b_local_off;
		input buf_sel;
		input [7:0] row_idx;
		begin
			make_b_local_off = {1'b0, buf_sel, row_to_b_elem(row_idx)};
		end
	endfunction

	function [7:0] row_to_a_elem;
		input [7:0] row_idx;
		begin
			row_to_a_elem = row_idx << A_DIM_SHIFT;
		end
	endfunction

	function [7:0] row_to_b_elem;
		input [7:0] row_idx;
		begin
			row_to_b_elem = row_idx << B_DIM_SHIFT;
		end
	endfunction

	// ingress command queue
	wire [IQ_WIDTH-1:0] cmd_q_out_data;
	wire                cmd_q_out_valid;
	wire                cmd_q_out_ready;
	wire                cmd_q_in_ready;
	wire [`INST_WIDTH-1:0] cmd_inst = cmd_q_out_data[IQ_WIDTH-1:32];
	wire [31:0]            cmd_id   = cmd_q_out_data[31:0];

	sync_fifo #(
		.WIDTH(IQ_WIDTH),
		.DEPTH(`QUEUE_LEN)
	) cmd_queue (
		.clk      (clk            ),
		.resetn   (rstn           ),
		.clear    (clear          ),
		.data_in  ({ctrl_inst, ctrl_id}),
		.valid_in (ctrl_valid     ),
		.ready_in (cmd_q_in_ready ),
		.data_out (cmd_q_out_data ),
		.valid_out(cmd_q_out_valid),
		.ready_out(cmd_q_out_ready)
	);

	assign ctrl_ready     = cmd_q_in_ready;
	assign cmd_q_out_ready = (state == ST_IDLE) || (state == ST_QCFG_LOAD);

	// CE issue queue
	reg [`INST_WIDTH-1:0] enq_inst;
	reg [31:0]            enq_id;
	wire [IQ_WIDTH-1:0]   ce_q_out_data;
	wire                  ce_q_out_valid;
	wire                  ce_q_out_ready;
	wire                  ce_q_in_ready;

	sync_fifo #(
		.WIDTH(IQ_WIDTH),
		.DEPTH(`QUEUE_LEN)
	) ce_queue (
		.clk      (clk             ),
		.resetn   (rstn            ),
		.clear    (clear           ),
		.data_in  ({enq_inst, enq_id}),
		.valid_in (state == ST_ENQ_CE),
		.ready_in (ce_q_in_ready   ),
		.data_out (ce_q_out_data   ),
		.valid_out(ce_q_out_valid  ),
		.ready_out(ce_q_out_ready  )
	);

	// CE issue is gated by M export buffer availability to avoid overwrite.
	wire m_buf0_free;
	wire m_buf1_free;
	wire m_buf_target_free;
	wire ce_can_issue;
	assign ce_can_issue     = m_buf_target_free;
	assign ce_inst_valid    = ce_q_out_valid && ce_can_issue;
	assign ce_inst        = ce_q_out_data[IQ_WIDTH-1:32];
	assign ce_id          = ce_q_out_data[31:0];
	assign ce_q_out_ready = ce_inst_ready && ce_can_issue;

	// current command
	reg [`INST_WIDTH-1:0] cur_inst;
	reg [31:0]            cur_id;

	wire [3:0] cmd_opcode = cmd_inst[`PT_INST_OPCODE_H:`PT_INST_OPCODE_L];
	wire [1:0] cmd_m      = cmd_inst[`PT_INST_M_H:`PT_INST_M_L];
	wire [1:0] cmd_n      = cmd_inst[`PT_INST_N_H:`PT_INST_N_L];
	wire [1:0] cmd_k      = cmd_inst[`PT_INST_K_H:`PT_INST_K_L];
	wire [9:0] cmd_a_off  = cmd_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] cmd_b_off  = cmd_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
	wire [3:0] cmd_qcfg_cmd = cmd_inst[`PT_QCFG_CMD_H:`PT_QCFG_CMD_L];
	wire [1:0] cmd_qcfg_qtype = cmd_inst[`PT_QCFG_QTYPE_H:`PT_QCFG_QTYPE_L];
	wire [2:0] cmd_qcfg_gran = cmd_inst[`PT_QCFG_GRAN_H:`PT_QCFG_GRAN_L];

	wire [9:0] cur_a_off  = cur_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] cur_b_off  = cur_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
	wire       cur_a_is_m = cur_a_off[9];
	wire       cur_b_is_m = cur_b_off[9];

	wire cmd_mnk_is_full = (cmd_m == `PT_SCALE_FULL) &&
	                       (cmd_n == `PT_SCALE_FULL) &&
	                       (cmd_k == `PT_SCALE_FULL);

	wire cmd_a_row_aligned = ((cmd_a_off[7:0] & A_DIM_MASK_8) == 8'd0);
	wire cmd_b_row_aligned = ((cmd_b_off[7:0] & B_DIM_MASK_8) == 8'd0);

	// quantization configuration session context
	reg [31:0] qcfg_active_id;
	reg [QCFG_CNT_W-1:0] qcfg_expect_cnt;
	reg [QCFG_CNT_W-1:0] qcfg_recv_cnt;
	reg [2:0] qcfg_shadow_mode;
	reg [MAX_DIM*32-1:0] qcfg_shadow_inv_scale;

	reg qcfg_hdr_ok;
	reg qcfg_hdr_err;
	reg [QCFG_CNT_W-1:0] qcfg_hdr_cnt;

	always @(*) begin
		qcfg_hdr_ok  = 1'b0;
		qcfg_hdr_err = 1'b0;
		qcfg_hdr_cnt = {QCFG_CNT_W{1'b0}};

		if (cmd_qcfg_cmd == `PT_QCFG_CMD_HDR && cmd_qcfg_qtype == `PT_QTYPE_SYMMETRIC) begin
			case (cmd_qcfg_gran)
				`PT_QGRAN_PER_TENSOR: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = {{(QCFG_CNT_W-1){1'b0}}, 1'b1};
				end
				`PT_QGRAN_X_WISE: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = GEMM_X_DIM;
				end
				`PT_QGRAN_Y_WISE: begin
					qcfg_hdr_ok  = 1'b1;
					qcfg_hdr_cnt = GEMM_Y_DIM;
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

	// LUT
	reg              lut_valid     [0:LUT_DEPTH-1];
	reg [31:0]       lut_id        [0:LUT_DEPTH-1];
	reg              lut_a_valid   [0:LUT_DEPTH-1];
	reg              lut_a_buf     [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_a_loc_off [0:LUT_DEPTH-1];
	reg              lut_b_valid   [0:LUT_DEPTH-1];
	reg              lut_b_buf     [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_ext_off [0:LUT_DEPTH-1];
	reg [9:0]        lut_b_loc_off [0:LUT_DEPTH-1];

	reg [LUT_AW-1:0] lut_alloc_ptr;
	reg [LUT_AW-1:0] work_lut_idx;
	reg              lut_found;
	reg [LUT_AW-1:0] lut_found_idx;
	reg              a_hit;
	reg              b_hit;

	wire [LUT_AW-1:0] active_lut_idx = lut_found ? lut_found_idx : lut_alloc_ptr;
	wire a_need_dma = !cur_a_is_m && !a_hit;
	wire b_need_dma = !cur_b_is_m && !b_hit;

	integer li;
	always @(*) begin
		lut_found     = 1'b0;
		lut_found_idx = {LUT_AW{1'b0}};
		for (li = 0; li < LUT_DEPTH; li = li + 1) begin
			if (lut_valid[li] && (lut_id[li] == cur_id) && !lut_found) begin
				lut_found     = 1'b1;
				lut_found_idx = li[LUT_AW-1:0];
			end
		end

		a_hit = cur_a_is_m;
		b_hit = cur_b_is_m;
		if (lut_found) begin
			if (!cur_a_is_m) begin
				a_hit = lut_a_valid[lut_found_idx] &&
				        ((cur_a_off == lut_a_ext_off[lut_found_idx]) ||
				         (cur_a_off == lut_a_loc_off[lut_found_idx]));
			end
			if (!cur_b_is_m) begin
				b_hit = lut_b_valid[lut_found_idx] &&
				        ((cur_b_off == lut_b_ext_off[lut_found_idx]) ||
				         (cur_b_off == lut_b_loc_off[lut_found_idx]));
			end
		end
	end

	reg a_wr_buf_sel;
	reg b_wr_buf_sel;

	// DMA load context
	reg                   load_is_b;
	reg                   load_buf_sel;
	reg [9:0]             load_ext_off;
	reg [7:0]             load_row_base;
	reg [DMA_BEATS_W-1:0] load_total_beats;
	reg [DMA_BEATS_W-1:0] load_recv_count;

	wire [31:0] dma_base_sel = load_is_b ? pcsr_b_base : pcsr_a_base;
	wire [EXT_ADDR_W-1:0] dma_off_bytes =
		({{(EXT_ADDR_W-10){1'b0}}, load_ext_off} << ELEM_SHIFT);
	wire [DMA_BEATS_W-1:0] dma_a_row = load_recv_count >> A_DIM_SHIFT;
	wire [DMA_BEATS_W-1:0] dma_a_col = load_recv_count & A_DIM_MASK_DMA;
	wire [DMA_BEATS_W-1:0] dma_b_row = load_recv_count >> B_DIM_SHIFT;
	wire [DMA_BEATS_W-1:0] dma_b_col = load_recv_count & B_DIM_MASK_DMA;

	wire dma_tuser_mismatch = s_axis_tvalid &&
		((!load_is_b && (s_axis_tuser != MATRIX_A)) ||
		 ( load_is_b && (s_axis_tuser != MATRIX_B)));

	assign dma_req_valid      = (state == ST_DMA_REQ);
	assign dma_req_tuser      = load_is_b ? MATRIX_B : MATRIX_A;
	assign dma_req_id         = cur_id;
	assign dma_req_ext_addr   = dma_base_sel[EXT_ADDR_W-1:0] + dma_off_bytes;
	assign dma_req_local_addr = load_is_b ? make_b_local_off(load_buf_sel, load_row_base)
	                                     : make_a_local_off(load_buf_sel, load_row_base);
	assign dma_req_beats      = load_total_beats;
	assign s_axis_tready      = (state == ST_DMA_RECV);

	// M export control/status
	reg [1:0] m_buf_state0;
	reg [1:0] m_buf_state1;
	reg [29:0] m_buf_id0;
	reg [29:0] m_buf_id1;
	reg        next_wr_buf;

	reg [1:0]  exp_state;
	reg        exp_req_buf;
	reg [29:0] exp_req_id;
	reg        exp_active_buf;
	reg [29:0] exp_active_id;
	reg [A_AW-1:0] exp_row_idx;
	reg [B_LW-1:0] exp_col_idx;

	wire m_buf0_ready = (m_buf_state0 == MBUF_READY);
	wire m_buf1_ready = (m_buf_state1 == MBUF_READY);
	assign m_buf0_free = (m_buf_state0 == MBUF_FREE);
	assign m_buf1_free = (m_buf_state1 == MBUF_FREE);
	assign m_buf_target_free = next_wr_buf ? m_buf1_free : m_buf0_free;

	wire exp_has_ready = m_buf0_ready || m_buf1_ready;
	wire exp_pick_buf = (m_buf0_ready && m_buf1_ready) ? next_wr_buf : (m_buf1_ready ? 1'b1 : 1'b0);
	wire [29:0] exp_pick_id = exp_pick_buf ? m_buf_id1 : m_buf_id0;

	wire exp_last_beat = (exp_row_idx == (GEMM_X_DIM - 1)) &&
	                     (exp_col_idx == (GEMM_Y_DIM - 1));
	wire exp_fire = (exp_state == EXP_STREAM) && m_axis_tvalid && m_axis_tready;
	wire exp_dma_err_fire = (exp_state == EXP_WAIT_DONE) && m_dma_error;
	wire [31:0] exp_err_resp = pack_resp(1'b1, exp_active_buf, {2'b00, exp_active_id});

	assign m_dma_req_valid = (exp_state == EXP_REQ);
	assign m_dma_req_id    = {2'b00, exp_req_id};
	assign m_dma_req_buf   = exp_req_buf;
	assign m_dma_req_beats = EXP_BEATS[DMA_BEATS_W-1:0];

	assign exp_rd_en       = (exp_state == EXP_STREAM);
	assign exp_rd_buf      = exp_active_buf;
	assign exp_rd_addr     = exp_row_idx;

	assign m_axis_tvalid   = (exp_state == EXP_STREAM);
	assign m_axis_tdata    = exp_rd_data[exp_col_idx*DATA_WIDTH +: DATA_WIDTH];
	assign m_axis_tstrb    = {(DATA_WIDTH/8){1'b1}};
	assign m_axis_tlast    = exp_last_beat;
	assign m_axis_tkeep    = 1'b1;
	assign m_axis_tid      = 1'b0;
	assign m_axis_tdest    = 1'b0;
	assign m_axis_tuser    = {1'b0, exp_active_buf};

	reg [`INST_WIDTH-1:0] patched_inst;
	reg irq_r;
	assign irq = irq_r;

	integer ri;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			state <= ST_IDLE;
		end else if (clear) begin
			state <= ST_IDLE;
		end else begin
			state <= next_state;
		end
	end

	always @(*) begin
		next_state = state;
		case (state)
			ST_IDLE: begin
				if (cmd_q_out_valid) begin
					if ((cmd_opcode == `PT_OP_MATMUL) && cmd_mnk_is_full &&
					    cmd_a_row_aligned && cmd_b_row_aligned) begin
						next_state = ST_LUT_CHECK;
					end else if ((cmd_opcode == `PT_OP_QCFG) && qcfg_hdr_ok) begin
						next_state = ST_QCFG_LOAD;
					end
				end
			end

			ST_LUT_CHECK: begin
				if (!a_need_dma && !b_need_dma) begin
					next_state = ST_ENQ_CE;
				end else begin
					next_state = ST_DMA_REQ;
				end
			end

			ST_DMA_REQ: begin
				if (dma_req_ready) begin
					next_state = ST_DMA_RECV;
				end
			end

			ST_DMA_RECV: begin
				if (dma_error || dma_tuser_mismatch) begin
					next_state = ST_IDLE;
				end else if (s_axis_tvalid && (load_recv_count + 1'b1 >= load_total_beats)) begin
					if (!load_is_b && b_need_dma) begin
						next_state = ST_DMA_REQ;
					end else begin
						next_state = ST_ENQ_CE;
					end
				end
			end

			ST_ENQ_CE: begin
				if (ce_q_in_ready) begin
					next_state = ST_IDLE;
				end
			end

			ST_QCFG_LOAD: begin
				if (cmd_q_out_valid) begin
					next_state = ST_IDLE;
					if ((cmd_id == qcfg_active_id) && ((qcfg_recv_cnt + 1'b1) < qcfg_expect_cnt)) begin
						next_state = ST_QCFG_LOAD;
					end
				end
			end

			default: begin
				next_state = ST_IDLE;
			end
		endcase
	end

		always @(posedge clk or negedge rstn) begin
			if (!rstn) begin
				cur_inst         <= {`INST_WIDTH{1'b0}};
				cur_id           <= 32'd0;
				qcfg_active_id   <= 32'd0;
				qcfg_expect_cnt  <= {QCFG_CNT_W{1'b0}};
				qcfg_recv_cnt    <= {QCFG_CNT_W{1'b0}};
				qcfg_shadow_mode <= `PT_QGRAN_PER_TENSOR;
				qcfg_shadow_inv_scale <= {MAX_DIM{32'h0001_0000}};
				csr_a_base_lo_we <= 1'b0;
				csr_a_base_hi_we <= 1'b0;
				csr_b_base_lo_we <= 1'b0;
				csr_b_base_hi_we <= 1'b0;
				csr_cfg_wdata16  <= 16'd0;
				csr_quant_commit_we <= 1'b0;
				csr_quant_mode_wdata <= `PT_QGRAN_PER_TENSOR;
				csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
				lut_alloc_ptr    <= {LUT_AW{1'b0}};
				work_lut_idx     <= {LUT_AW{1'b0}};
			a_wr_buf_sel     <= 1'b0;
			b_wr_buf_sel     <= 1'b0;
			load_is_b        <= 1'b0;
			load_buf_sel     <= 1'b0;
			load_ext_off     <= 10'd0;
			load_row_base    <= 8'd0;
			load_total_beats <= {DMA_BEATS_W{1'b0}};
			load_recv_count  <= {DMA_BEATS_W{1'b0}};
			enq_inst         <= {`INST_WIDTH{1'b0}};
			enq_id           <= 32'd0;
			md_resp_valid    <= 1'b0;
			md_resp          <= 32'd0;
			irq_r            <= 1'b0;
			a_mem_wr_en      <= 1'b0;
			a_mem_wr_buf     <= 1'b0;
			a_mem_wr_lane    <= {A_LW{1'b0}};
			a_mem_wr_addr    <= {A_AW{1'b0}};
			a_mem_wr_data    <= {DATA_WIDTH{1'b0}};
			b_mem_wr_en      <= 1'b0;
			b_mem_wr_buf     <= 1'b0;
			b_mem_wr_lane    <= {B_LW{1'b0}};
			b_mem_wr_addr    <= {B_AW{1'b0}};
			b_mem_wr_data    <= {DATA_WIDTH{1'b0}};
			m_buf_state0     <= MBUF_FREE;
			m_buf_state1     <= MBUF_FREE;
			m_buf_id0        <= 30'd0;
			m_buf_id1        <= 30'd0;
			next_wr_buf      <= 1'b0;
			exp_state        <= EXP_IDLE;
			exp_req_buf      <= 1'b0;
			exp_req_id       <= 30'd0;
			exp_active_buf   <= 1'b0;
			exp_active_id    <= 30'd0;
			exp_row_idx      <= {A_AW{1'b0}};
			exp_col_idx      <= {B_LW{1'b0}};

			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_buf[ri]     <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_buf[ri]     <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
			end else if (clear) begin
				cur_inst         <= {`INST_WIDTH{1'b0}};
				cur_id           <= 32'd0;
				qcfg_active_id   <= 32'd0;
				qcfg_expect_cnt  <= {QCFG_CNT_W{1'b0}};
				qcfg_recv_cnt    <= {QCFG_CNT_W{1'b0}};
				qcfg_shadow_mode <= `PT_QGRAN_PER_TENSOR;
				qcfg_shadow_inv_scale <= {MAX_DIM{32'h0001_0000}};
				csr_a_base_lo_we <= 1'b0;
				csr_a_base_hi_we <= 1'b0;
				csr_b_base_lo_we <= 1'b0;
				csr_b_base_hi_we <= 1'b0;
				csr_cfg_wdata16  <= 16'd0;
				csr_quant_commit_we <= 1'b0;
				csr_quant_mode_wdata <= `PT_QGRAN_PER_TENSOR;
				csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
				lut_alloc_ptr    <= {LUT_AW{1'b0}};
				work_lut_idx     <= {LUT_AW{1'b0}};
			a_wr_buf_sel     <= 1'b0;
			b_wr_buf_sel     <= 1'b0;
			load_is_b        <= 1'b0;
			load_buf_sel     <= 1'b0;
			load_ext_off     <= 10'd0;
			load_row_base    <= 8'd0;
			load_total_beats <= {DMA_BEATS_W{1'b0}};
			load_recv_count  <= {DMA_BEATS_W{1'b0}};
			enq_inst         <= {`INST_WIDTH{1'b0}};
			enq_id           <= 32'd0;
			md_resp_valid    <= 1'b0;
			md_resp          <= 32'd0;
			irq_r            <= 1'b0;
			a_mem_wr_en      <= 1'b0;
			b_mem_wr_en      <= 1'b0;
			m_buf_state0     <= MBUF_FREE;
			m_buf_state1     <= MBUF_FREE;
			m_buf_id0        <= 30'd0;
			m_buf_id1        <= 30'd0;
			next_wr_buf      <= 1'b0;
			exp_state        <= EXP_IDLE;
			exp_req_buf      <= 1'b0;
			exp_req_id       <= 30'd0;
			exp_active_buf   <= 1'b0;
			exp_active_id    <= 30'd0;
			exp_row_idx      <= {A_AW{1'b0}};
			exp_col_idx      <= {B_LW{1'b0}};

			for (ri = 0; ri < LUT_DEPTH; ri = ri + 1) begin
				lut_valid[ri]     <= 1'b0;
				lut_id[ri]        <= 32'd0;
				lut_a_valid[ri]   <= 1'b0;
				lut_a_buf[ri]     <= 1'b0;
				lut_a_ext_off[ri] <= 10'd0;
				lut_a_loc_off[ri] <= 10'd0;
				lut_b_valid[ri]   <= 1'b0;
				lut_b_buf[ri]     <= 1'b0;
				lut_b_ext_off[ri] <= 10'd0;
				lut_b_loc_off[ri] <= 10'd0;
			end
			end else begin
				md_resp_valid <= 1'b0;
				irq_r         <= 1'b0;
				a_mem_wr_en   <= 1'b0;
				b_mem_wr_en   <= 1'b0;
				csr_a_base_lo_we <= 1'b0;
				csr_a_base_hi_we <= 1'b0;
				csr_b_base_lo_we <= 1'b0;
				csr_b_base_hi_we <= 1'b0;
				csr_quant_commit_we <= 1'b0;

				if (ce_resp_valid && !ce_resp[31]) begin
				next_wr_buf <= ~ce_resp[30];
				if (ce_resp[30]) begin
					m_buf_state1 <= MBUF_READY;
					m_buf_id1    <= ce_resp[29:0];
				end else begin
					m_buf_state0 <= MBUF_READY;
					m_buf_id0    <= ce_resp[29:0];
				end
			end

				case (state)
						ST_IDLE: begin
							if (cmd_q_out_valid) begin
								if (cmd_opcode == `PT_OP_CFG) begin
								csr_cfg_wdata16 <= cmd_inst[15:0];
								case (cmd_inst[27:24])
									`PT_CFG_A_BASE_LO: csr_a_base_lo_we <= 1'b1;
									`PT_CFG_A_BASE_HI: csr_a_base_hi_we <= 1'b1;
									`PT_CFG_B_BASE_LO: csr_b_base_lo_we <= 1'b1;
									`PT_CFG_B_BASE_HI: csr_b_base_hi_we <= 1'b1;
									default: begin
									end
								endcase
									md_resp       <= pack_resp(1'b0, 1'b0, cmd_id);
									md_resp_valid <= 1'b1;
							end else if (cmd_opcode == `PT_OP_QCFG) begin
								if (!qcfg_hdr_ok || (qcfg_hdr_cnt == {QCFG_CNT_W{1'b0}}) || qcfg_hdr_err) begin
									md_resp       <= pack_resp(1'b1, 1'b0, cmd_id);
									md_resp_valid <= 1'b1;
									irq_r         <= 1'b1;
								end else begin
									qcfg_active_id   <= cmd_id;
									qcfg_expect_cnt  <= qcfg_hdr_cnt;
									qcfg_recv_cnt    <= {QCFG_CNT_W{1'b0}};
									qcfg_shadow_mode <= cmd_qcfg_gran;
									qcfg_shadow_inv_scale <= csr_quant_inv_scale;
								end
							end else if (cmd_opcode == `PT_OP_MATMUL) begin
								if (!cmd_mnk_is_full || !cmd_a_row_aligned || !cmd_b_row_aligned) begin
									md_resp       <= pack_resp(1'b1, 1'b0, cmd_id);
								md_resp_valid <= 1'b1;
								irq_r         <= 1'b1;
							end else begin
								cur_inst <= cmd_inst;
								cur_id   <= cmd_id;
							end
						end else begin
							md_resp       <= pack_resp(1'b1, 1'b0, cmd_id);
							md_resp_valid <= 1'b1;
							irq_r         <= 1'b1;
						end
					end
				end

				ST_LUT_CHECK: begin
					work_lut_idx <= active_lut_idx;
					if (!lut_found && (!cur_a_is_m || !cur_b_is_m)) begin
						lut_valid[lut_alloc_ptr]     <= 1'b1;
						lut_id[lut_alloc_ptr]        <= cur_id;
						lut_a_valid[lut_alloc_ptr]   <= 1'b0;
						lut_b_valid[lut_alloc_ptr]   <= 1'b0;
						lut_a_ext_off[lut_alloc_ptr] <= 10'd0;
						lut_a_loc_off[lut_alloc_ptr] <= 10'd0;
						lut_b_ext_off[lut_alloc_ptr] <= 10'd0;
						lut_b_loc_off[lut_alloc_ptr] <= 10'd0;
						lut_alloc_ptr <= lut_alloc_ptr + 1'b1;
					end

					if (!a_need_dma && !b_need_dma) begin
						patched_inst = cur_inst;
						if (!cur_a_is_m) begin
							patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = lut_a_loc_off[active_lut_idx];
						end
						if (!cur_b_is_m) begin
							patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = lut_b_loc_off[active_lut_idx];
						end
						enq_inst <= patched_inst;
						enq_id   <= cur_id;
					end else if (a_need_dma) begin
						load_is_b        <= 1'b0;
						load_buf_sel     <= a_wr_buf_sel;
						load_ext_off     <= cur_a_off;
							load_row_base    <= cur_a_off[7:0] >> A_DIM_SHIFT;
							load_total_beats <= A_ELEMS[DMA_BEATS_W-1:0];
							load_recv_count  <= {DMA_BEATS_W{1'b0}};
						end else begin
							load_is_b        <= 1'b1;
							load_buf_sel     <= b_wr_buf_sel;
							load_ext_off     <= cur_b_off;
							load_row_base    <= cur_b_off[7:0] >> B_DIM_SHIFT;
							load_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
							load_recv_count  <= {DMA_BEATS_W{1'b0}};
						end
				end

				ST_DMA_REQ: begin
					if (dma_req_ready) begin
						load_recv_count <= {DMA_BEATS_W{1'b0}};
					end
				end

				ST_DMA_RECV: begin
						if (dma_error || dma_tuser_mismatch) begin
							md_resp       <= pack_resp(1'b1, 1'b0, cur_id);
							md_resp_valid <= 1'b1;
							irq_r         <= 1'b1;
						end else if (s_axis_tvalid) begin
							if (!load_is_b) begin
								a_mem_wr_en   <= 1'b1;
								a_mem_wr_buf  <= load_buf_sel;
								a_mem_wr_lane <= dma_a_row[A_LW-1:0];
								a_mem_wr_addr <= load_row_base[A_AW-1:0] + dma_a_col[A_AW-1:0];
								a_mem_wr_data <= s_axis_tdata;
							end else begin
								b_mem_wr_en   <= 1'b1;
								b_mem_wr_buf  <= load_buf_sel;
								b_mem_wr_lane <= dma_b_col[B_LW-1:0];
								b_mem_wr_addr <= load_row_base[B_AW-1:0] + dma_b_row[B_AW-1:0];
								b_mem_wr_data <= s_axis_tdata;
							end

						load_recv_count <= load_recv_count + 1'b1;
					end

					if (s_axis_tvalid && (load_recv_count + 1'b1 >= load_total_beats) &&
					    !dma_error && !dma_tuser_mismatch) begin
						if (!load_is_b) begin
							lut_a_valid[work_lut_idx]   <= 1'b1;
							lut_a_buf[work_lut_idx]     <= load_buf_sel;
							lut_a_ext_off[work_lut_idx] <= load_ext_off;
							lut_a_loc_off[work_lut_idx] <= make_a_local_off(load_buf_sel, load_row_base);
							a_wr_buf_sel                <= ~a_wr_buf_sel;
								if (b_need_dma) begin
									load_is_b        <= 1'b1;
									load_buf_sel     <= b_wr_buf_sel;
									load_ext_off     <= cur_b_off;
									load_row_base    <= cur_b_off[7:0] >> B_DIM_SHIFT;
									load_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
									load_recv_count  <= {DMA_BEATS_W{1'b0}};
								end else begin
								patched_inst = cur_inst;
								patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = make_a_local_off(load_buf_sel, load_row_base);
								if (!cur_b_is_m) begin
									patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = lut_b_loc_off[work_lut_idx];
								end
								enq_inst <= patched_inst;
								enq_id   <= cur_id;
							end
						end else begin
							lut_b_valid[work_lut_idx]   <= 1'b1;
							lut_b_buf[work_lut_idx]     <= load_buf_sel;
							lut_b_ext_off[work_lut_idx] <= load_ext_off;
							lut_b_loc_off[work_lut_idx] <= make_b_local_off(load_buf_sel, load_row_base);
							b_wr_buf_sel                <= ~b_wr_buf_sel;
							patched_inst = cur_inst;
							if (!cur_a_is_m) begin
								patched_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L] = lut_a_loc_off[work_lut_idx];
							end
							patched_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L] = make_b_local_off(load_buf_sel, load_row_base);
							enq_inst <= patched_inst;
							enq_id   <= cur_id;
						end
					end
				end

					ST_ENQ_CE: begin
						// success response is produced by CE completion only
					end

					ST_QCFG_LOAD: begin
						if (cmd_q_out_valid) begin
							if (cmd_id != qcfg_active_id) begin
								md_resp       <= pack_resp(1'b1, 1'b0, qcfg_active_id);
								md_resp_valid <= 1'b1;
								irq_r         <= 1'b1;
								qcfg_expect_cnt <= {QCFG_CNT_W{1'b0}};
								qcfg_recv_cnt   <= {QCFG_CNT_W{1'b0}};
							end else begin
									qcfg_shadow_inv_scale[qcfg_recv_cnt*32 +: 32] <= cmd_inst;
									if ((qcfg_recv_cnt + 1'b1) >= qcfg_expect_cnt) begin
										csr_quant_mode_wdata <= qcfg_shadow_mode;
										for (ri = 0; ri < MAX_DIM; ri = ri + 1) begin
											if (ri == qcfg_recv_cnt) begin
												csr_quant_inv_scale_wdata[ri*32 +: 32] <= cmd_inst;
											end else begin
												csr_quant_inv_scale_wdata[ri*32 +: 32] <= qcfg_shadow_inv_scale[ri*32 +: 32];
											end
										end
										csr_quant_commit_we <= 1'b1;
										md_resp       <= pack_resp(1'b0, 1'b0, qcfg_active_id);
										md_resp_valid <= 1'b1;
									qcfg_expect_cnt <= {QCFG_CNT_W{1'b0}};
									qcfg_recv_cnt   <= {QCFG_CNT_W{1'b0}};
								end else begin
									qcfg_recv_cnt <= qcfg_recv_cnt + 1'b1;
								end
							end
						end
					end

						default: begin
						end
					endcase

			case (exp_state)
				EXP_IDLE: begin
					if (exp_has_ready) begin
						exp_req_buf <= exp_pick_buf;
						exp_req_id  <= exp_pick_id;
						exp_state   <= EXP_REQ;
					end
				end

				EXP_REQ: begin
					if (m_dma_req_ready) begin
						exp_active_buf <= exp_req_buf;
						exp_active_id  <= exp_req_id;
						exp_row_idx    <= {A_AW{1'b0}};
						exp_col_idx    <= {B_LW{1'b0}};
						if (exp_req_buf) begin
							m_buf_state1 <= MBUF_EXPORTING;
						end else begin
							m_buf_state0 <= MBUF_EXPORTING;
						end
						exp_state <= EXP_STREAM;
					end
				end

				EXP_STREAM: begin
					if (exp_fire) begin
						if (exp_last_beat) begin
							exp_state <= EXP_WAIT_DONE;
						end else if (exp_col_idx == (GEMM_Y_DIM - 1)) begin
							exp_col_idx <= {B_LW{1'b0}};
							exp_row_idx <= exp_row_idx + 1'b1;
						end else begin
							exp_col_idx <= exp_col_idx + 1'b1;
						end
					end
				end

				EXP_WAIT_DONE: begin
					if (m_dma_done || m_dma_error) begin
						if (exp_active_buf) begin
							m_buf_state1 <= MBUF_FREE;
						end else begin
							m_buf_state0 <= MBUF_FREE;
						end
						if (m_dma_error) begin
							md_resp       <= exp_err_resp;
							md_resp_valid <= 1'b1;
							irq_r         <= 1'b1;
						end
						exp_state <= EXP_IDLE;
					end
				end

				default: begin
					exp_state <= EXP_IDLE;
				end
			endcase
		end
	end

	// keep currently unused DMA input explicitly referenced
	wire _unused_dma_done = dma_done;

endmodule
