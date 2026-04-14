`include "param.vh"

`ifdef PT_KEEP_LEGACY
module PT_MD #(
	parameter DATA_WIDTH   = 32,
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter EXT_ADDR_W   = 32,
	parameter DMA_BEATS_W  = 16,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,

	input  wire                       mem_cmd_valid,
	output wire                       mem_cmd_ready,
	input  wire [`PT_MEM_KIND_W-1:0]  mem_cmd_kind,
	input  wire [`INST_WIDTH-1:0]     mem_cmd_inst,
	input  wire [31:0]                mem_cmd_id,
	input  wire [15:0]                mem_cmd_seq,

	input  wire                       miss_req_valid,
	output wire                       miss_req_ready,
	input  wire [31:0]                miss_req_id,
	input  wire [9:0]                 miss_req_a_off,
	input  wire [9:0]                 miss_req_b_off,
	input  wire                       miss_req_need_a,
	input  wire                       miss_req_need_b,

	output reg                        mem_done_valid,
	output reg  [31:0]                mem_done_id,
	output reg  [15:0]                mem_done_seq,
	output reg                        mem_done_err,
	output reg                        load_done_valid,
	output reg  [31:0]                load_done_id,
	output reg                        load_done_side,
	output reg                        load_done_buf,
	output reg  [9:0]                 load_done_local_off,
	output reg  [9:0]                 load_done_ext_off,
	output reg                        miss_done_valid,
	output reg  [31:0]                miss_done_id,
	output reg                        miss_done_err,
	output wire                       ce_issue_ok,

	output reg                        md_resp_valid,
	output reg  [31:0]                md_resp,

	input  wire                       s_axis_tvalid,
	input  wire [DATA_WIDTH-1:0]      s_axis_tdata,
	input  wire [1:0]                 s_axis_tuser,
	output wire                       s_axis_tready,

	output wire                       dma_req_valid,
	input  wire                       dma_req_ready,
	output wire [1:0]                 dma_req_tuser,
	output wire [31:0]                dma_req_id,
	output wire [EXT_ADDR_W-1:0]      dma_req_ext_addr,
	output wire [9:0]                 dma_req_local_addr,
	output wire [DMA_BEATS_W-1:0]     dma_req_beats,
	input  wire                       dma_done,
	input  wire                       dma_error,

	output reg                        a_mem_wr_en,
	output reg                        a_mem_wr_buf,
	output reg  [((GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM))-1:0] a_mem_wr_lane,
	output reg  [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] a_mem_wr_addr,
	output reg  [DATA_WIDTH-1:0]      a_mem_wr_data,

	output reg                        b_mem_wr_en,
	output reg                        b_mem_wr_buf,
	output reg  [((GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM))-1:0] b_mem_wr_lane,
	output reg  [((B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH))-1:0] b_mem_wr_addr,
	output reg  [DATA_WIDTH-1:0]      b_mem_wr_data,

	input  wire                       ce_resp_valid,
	input  wire [31:0]                ce_resp,

	output wire                       m_dma_req_valid,
	input  wire                       m_dma_req_ready,
	output wire [31:0]                m_dma_req_id,
	output wire                       m_dma_req_buf,
	output wire [DMA_BEATS_W-1:0]     m_dma_req_beats,
	input  wire                       m_dma_done,
	input  wire                       m_dma_error,

	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [DATA_WIDTH-1:0]      m_axis_tdata,
	output wire [DATA_WIDTH/8-1:0]    m_axis_tstrb,
	output wire                       m_axis_tlast,
	output wire                       m_axis_tkeep,
	output wire                       m_axis_tid,
	output wire                       m_axis_tdest,
	output wire [1:0]                 m_axis_tuser,

	output wire                       exp_rd_en,
	output wire                       exp_rd_buf,
	output wire [((A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH))-1:0] exp_rd_addr,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_rd_data,

	input  wire [31:0]                pcsr_a_base,
	input  wire [31:0]                pcsr_b_base,
	input  wire [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale,

	output reg                        csr_a_base_lo_we,
	output reg                        csr_a_base_hi_we,
	output reg                        csr_b_base_lo_we,
	output reg                        csr_b_base_hi_we,
	output reg  [15:0]                csr_cfg_wdata16,
	output reg                        csr_quant_commit_we,
	output reg  [2:0]                 csr_quant_mode_wdata,
	output reg  [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale_wdata,

	output wire                       irq
);

	localparam [1:0] MATRIX_A = 2'b01;
	localparam [1:0] MATRIX_B = 2'b10;

	localparam integer A_ELEMS = GEMM_X_DIM * GEMM_X_DIM;
	localparam integer B_ELEMS = GEMM_Y_DIM * GEMM_Y_DIM;
	localparam integer A_LW    = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW    = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_AW    = (A_BANK_DEPTH <= 1) ? 1 : $clog2(A_BANK_DEPTH);
	localparam integer B_AW    = (B_BANK_DEPTH <= 1) ? 1 : $clog2(B_BANK_DEPTH);
	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer QCFG_CNT_W = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM + 1);
	localparam integer ELEM_SHIFT = (DATA_WIDTH <= 8) ? 0 : $clog2(DATA_WIDTH / 8);
	localparam integer A_DIM_CONST = (GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM;
	localparam integer B_DIM_CONST = (GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM;
	localparam integer A_DIM_SHIFT = $clog2(A_DIM_CONST);
	localparam integer B_DIM_SHIFT = $clog2(B_DIM_CONST);
	localparam [DMA_BEATS_W-1:0] A_DIM_MASK_DMA = A_DIM_CONST - 1;
	localparam [DMA_BEATS_W-1:0] B_DIM_MASK_DMA = B_DIM_CONST - 1;
	localparam integer EXP_BEATS = GEMM_X_DIM * GEMM_Y_DIM;

	localparam [1:0] ST_IDLE    = 2'd0;
	localparam [1:0] ST_DMA_REQ = 2'd1;
	localparam [1:0] ST_DMA_RECV = 2'd2;

	localparam [1:0] MBUF_FREE      = 2'd0;
	localparam [1:0] MBUF_READY     = 2'd1;
	localparam [1:0] MBUF_EXPORTING = 2'd2;

	localparam [1:0] EXP_IDLE      = 2'd0;
	localparam [1:0] EXP_REQ       = 2'd1;
	localparam [1:0] EXP_STREAM    = 2'd2;
	localparam [1:0] EXP_WAIT_DONE = 2'd3;

	reg [1:0] exec_state;
	reg [1:0] exec_next_state;

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
			make_a_local_off = {1'b0, buf_sel, row_idx << A_DIM_SHIFT};
		end
	endfunction

	function [9:0] make_b_local_off;
		input buf_sel;
		input [7:0] row_idx;
		begin
			make_b_local_off = {1'b0, buf_sel, row_idx << B_DIM_SHIFT};
		end
	endfunction

	wire [3:0] cmd_qcfg_cmd = mem_cmd_inst[`PT_QCFG_CMD_H:`PT_QCFG_CMD_L];
	wire [1:0] cmd_qcfg_qtype = mem_cmd_inst[`PT_QCFG_QTYPE_H:`PT_QCFG_QTYPE_L];
	wire [2:0] cmd_qcfg_gran = mem_cmd_inst[`PT_QCFG_GRAN_H:`PT_QCFG_GRAN_L];
	wire [9:0] cmd_load_a_off = mem_cmd_inst[`PT_INST_A_OFF_H:`PT_INST_A_OFF_L];
	wire [9:0] cmd_load_b_off = mem_cmd_inst[`PT_INST_B_OFF_H:`PT_INST_B_OFF_L];
	wire       cmd_load_need_a = mem_cmd_inst[`PT_LOAD_NEED_A_BIT];
	wire       cmd_load_need_b = mem_cmd_inst[`PT_LOAD_NEED_B_BIT];

	reg qcfg_hdr_ok;
	reg qcfg_hdr_err;
	reg [QCFG_CNT_W-1:0] qcfg_hdr_cnt;
	always @(*) begin
		qcfg_hdr_ok  = 1'b0;
		qcfg_hdr_err = 1'b0;
		qcfg_hdr_cnt = {QCFG_CNT_W{1'b0}};
		if ((cmd_qcfg_cmd == `PT_QCFG_CMD_HDR) && (cmd_qcfg_qtype == `PT_QTYPE_SYMMETRIC)) begin
			case (cmd_qcfg_gran)
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

	reg [31:0] qcfg_active_id;
	reg [QCFG_CNT_W-1:0] qcfg_expect_cnt;
	reg [QCFG_CNT_W-1:0] qcfg_recv_cnt;
	reg [2:0] qcfg_shadow_mode;
	reg [MAX_DIM*32-1:0] qcfg_shadow_inv_scale;

	reg        a_wr_buf_sel;
	reg        b_wr_buf_sel;
	reg        svc_is_miss;
	reg [31:0] svc_id;
	reg [15:0] svc_seq;
	reg        svc_need_a;
	reg        svc_need_b;
	reg [9:0]  svc_a_off;
	reg [9:0]  svc_b_off;
	reg        svc_is_b;
	reg        svc_buf_sel;
	reg [9:0]  svc_ext_off;
	reg [7:0]  svc_row_base;
	reg [DMA_BEATS_W-1:0] svc_total_beats;
	reg [DMA_BEATS_W-1:0] svc_recv_count;

	wire [31:0] dma_base_sel = svc_is_b ? pcsr_b_base : pcsr_a_base;
	wire [EXT_ADDR_W-1:0] dma_off_bytes = ({{(EXT_ADDR_W-10){1'b0}}, svc_ext_off} << ELEM_SHIFT);
	wire [DMA_BEATS_W-1:0] dma_a_row = svc_recv_count >> A_DIM_SHIFT;
	wire [DMA_BEATS_W-1:0] dma_a_col = svc_recv_count & A_DIM_MASK_DMA;
	wire [DMA_BEATS_W-1:0] dma_b_row = svc_recv_count >> B_DIM_SHIFT;
	wire [DMA_BEATS_W-1:0] dma_b_col = svc_recv_count & B_DIM_MASK_DMA;
	wire dma_tuser_mismatch = s_axis_tvalid &&
		((!svc_is_b && (s_axis_tuser != MATRIX_A)) ||
		 ( svc_is_b && (s_axis_tuser != MATRIX_B)));

	assign dma_req_valid      = (exec_state == ST_DMA_REQ);
	assign dma_req_tuser      = svc_is_b ? MATRIX_B : MATRIX_A;
	assign dma_req_id         = svc_id;
	assign dma_req_ext_addr   = dma_base_sel[EXT_ADDR_W-1:0] + dma_off_bytes;
	assign dma_req_local_addr = svc_is_b ? make_b_local_off(svc_buf_sel, svc_row_base)
	                                     : make_a_local_off(svc_buf_sel, svc_row_base);
	assign dma_req_beats      = svc_total_beats;
	assign s_axis_tready      = (exec_state == ST_DMA_RECV);

	assign miss_req_ready = (exec_state == ST_IDLE);
	assign mem_cmd_ready  = (exec_state == ST_IDLE) && !miss_req_valid;

	reg [1:0] m_buf_state0;
	reg [1:0] m_buf_state1;
	reg [29:0] m_buf_id0;
	reg [29:0] m_buf_id1;
	reg        next_wr_buf;

	wire m_buf0_ready = (m_buf_state0 == MBUF_READY);
	wire m_buf1_ready = (m_buf_state1 == MBUF_READY);
	wire m_buf0_free  = (m_buf_state0 == MBUF_FREE);
	wire m_buf1_free  = (m_buf_state1 == MBUF_FREE);
	wire m_buf_target_free = next_wr_buf ? m_buf1_free : m_buf0_free;
	assign ce_issue_ok = m_buf_target_free;

	reg [1:0] exp_state;
	reg [1:0] exp_next_state;
	reg        exp_req_buf;
	reg [29:0] exp_req_id;
	reg        exp_active_buf;
	reg [29:0] exp_active_id;
	reg [A_AW-1:0] exp_row_idx;
	reg [B_LW-1:0] exp_col_idx;
	reg [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_row_data;
	reg        exp_row_valid;
	reg        exp_row_fetch_pending;
	reg [A_AW-1:0] exp_fetch_row_idx;

	wire exp_has_ready = m_buf0_ready || m_buf1_ready;
	wire exp_pick_buf = (m_buf0_ready && m_buf1_ready) ? next_wr_buf : (m_buf1_ready ? 1'b1 : 1'b0);
	wire [29:0] exp_pick_id = exp_pick_buf ? m_buf_id1 : m_buf_id0;
	wire exp_last_beat = exp_row_valid &&
	                     (exp_row_idx == (GEMM_X_DIM - 1)) &&
	                     (exp_col_idx == (GEMM_Y_DIM - 1));
	wire exp_fire = (exp_state == EXP_STREAM) && exp_row_valid && m_axis_tready;
	wire exp_prime_req = (exp_state == EXP_STREAM) && !exp_row_valid && !exp_row_fetch_pending;
	wire exp_prefetch_req = (exp_state == EXP_STREAM) &&
	                        exp_row_valid &&
	                        exp_fire &&
	                        (exp_col_idx == (GEMM_Y_DIM - 1)) &&
	                        (exp_row_idx != (GEMM_X_DIM - 1));
	wire exp_row_req = exp_prime_req || exp_prefetch_req;
	wire [A_AW-1:0] exp_req_row_addr = exp_prime_req ? exp_row_idx : (exp_row_idx + 1'b1);
	wire exp_dma_err_fire = (exp_state == EXP_WAIT_DONE) && m_dma_error;
	wire [31:0] exp_err_resp = pack_resp(1'b1, exp_active_buf, {2'b00, exp_active_id});

	assign m_dma_req_valid = (exp_state == EXP_REQ);
	assign m_dma_req_id    = {2'b00, exp_req_id};
	assign m_dma_req_buf   = exp_req_buf;
	assign m_dma_req_beats = EXP_BEATS[DMA_BEATS_W-1:0];

	assign exp_rd_en   = exp_row_req;
	assign exp_rd_buf  = exp_active_buf;
	assign exp_rd_addr = exp_req_row_addr;

	assign m_axis_tvalid = (exp_state == EXP_STREAM) && exp_row_valid;
	assign m_axis_tdata  = exp_row_data[exp_col_idx*DATA_WIDTH +: DATA_WIDTH];
	assign m_axis_tstrb  = {(DATA_WIDTH/8){1'b1}};
	assign m_axis_tlast  = exp_last_beat;
	assign m_axis_tkeep  = 1'b1;
	assign m_axis_tid    = 1'b0;
	assign m_axis_tdest  = 1'b0;
	assign m_axis_tuser  = {1'b0, exp_active_buf};

	reg irq_r;
	assign irq = irq_r;

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			exec_state <= ST_IDLE;
		end else if (clear) begin
			exec_state <= ST_IDLE;
		end else begin
			exec_state <= exec_next_state;
		end
	end

	always @(*) begin
		exec_next_state = exec_state;
		case (exec_state)
			ST_IDLE: begin
				if (miss_req_valid) begin
					exec_next_state = ST_DMA_REQ;
				end else if (mem_cmd_valid) begin
					case (mem_cmd_kind)
						`PT_MEM_KIND_LOAD: begin
							if (cmd_load_need_a || cmd_load_need_b) begin
								exec_next_state = ST_DMA_REQ;
							end
						end

						default: begin
						end
					endcase
				end
			end

			ST_DMA_REQ: begin
				if (dma_req_ready) begin
					exec_next_state = ST_DMA_RECV;
				end
			end

			ST_DMA_RECV: begin
				if (dma_error || dma_tuser_mismatch) begin
					exec_next_state = ST_IDLE;
				end else if (s_axis_tvalid && ((svc_recv_count + 1'b1) >= svc_total_beats)) begin
					if (!svc_is_b && svc_need_b) begin
						exec_next_state = ST_DMA_REQ;
					end else begin
						exec_next_state = ST_IDLE;
					end
				end
			end

			default: begin
				exec_next_state = ST_IDLE;
			end
		endcase
	end

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			exp_state <= EXP_IDLE;
		end else if (clear) begin
			exp_state <= EXP_IDLE;
		end else begin
			exp_state <= exp_next_state;
		end
	end

	always @(*) begin
		exp_next_state = exp_state;
		case (exp_state)
			EXP_IDLE: begin
				if (exp_has_ready) begin
					exp_next_state = EXP_REQ;
				end
			end

			EXP_REQ: begin
				if (m_dma_req_ready) begin
					exp_next_state = EXP_STREAM;
				end
			end

			EXP_STREAM: begin
				if (exp_fire && exp_last_beat) begin
					exp_next_state = EXP_WAIT_DONE;
				end
			end

			EXP_WAIT_DONE: begin
				if (m_dma_done || m_dma_error) begin
					exp_next_state = EXP_IDLE;
				end
			end

			default: begin
				exp_next_state = EXP_IDLE;
			end
		endcase
	end

	integer ri;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			mem_done_valid      <= 1'b0;
			mem_done_id         <= 32'd0;
			mem_done_seq        <= 16'd0;
			mem_done_err        <= 1'b0;
			load_done_valid     <= 1'b0;
			load_done_id        <= 32'd0;
			load_done_side      <= 1'b0;
			load_done_buf       <= 1'b0;
			load_done_local_off <= 10'd0;
			load_done_ext_off   <= 10'd0;
			miss_done_valid     <= 1'b0;
			miss_done_id        <= 32'd0;
			miss_done_err       <= 1'b0;
			md_resp_valid       <= 1'b0;
			md_resp             <= 32'd0;
			a_mem_wr_en         <= 1'b0;
			a_mem_wr_buf        <= 1'b0;
			a_mem_wr_lane       <= {A_LW{1'b0}};
			a_mem_wr_addr       <= {A_AW{1'b0}};
			a_mem_wr_data       <= {DATA_WIDTH{1'b0}};
			b_mem_wr_en         <= 1'b0;
			b_mem_wr_buf        <= 1'b0;
			b_mem_wr_lane       <= {B_LW{1'b0}};
			b_mem_wr_addr       <= {B_AW{1'b0}};
			b_mem_wr_data       <= {DATA_WIDTH{1'b0}};
			csr_a_base_lo_we    <= 1'b0;
			csr_a_base_hi_we    <= 1'b0;
			csr_b_base_lo_we    <= 1'b0;
			csr_b_base_hi_we    <= 1'b0;
			csr_cfg_wdata16     <= 16'd0;
			csr_quant_commit_we <= 1'b0;
			csr_quant_mode_wdata <= `PT_QGRAN_PER_TENSOR;
			csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
			qcfg_active_id      <= 32'd0;
			qcfg_expect_cnt     <= {QCFG_CNT_W{1'b0}};
			qcfg_recv_cnt       <= {QCFG_CNT_W{1'b0}};
			qcfg_shadow_mode    <= `PT_QGRAN_PER_TENSOR;
			qcfg_shadow_inv_scale <= {MAX_DIM{32'h0001_0000}};
			a_wr_buf_sel        <= 1'b0;
			b_wr_buf_sel        <= 1'b0;
			svc_is_miss         <= 1'b0;
			svc_id              <= 32'd0;
			svc_seq             <= 16'd0;
			svc_need_a          <= 1'b0;
			svc_need_b          <= 1'b0;
			svc_a_off           <= 10'd0;
			svc_b_off           <= 10'd0;
			svc_is_b            <= 1'b0;
			svc_buf_sel         <= 1'b0;
			svc_ext_off         <= 10'd0;
			svc_row_base        <= 8'd0;
			svc_total_beats     <= {DMA_BEATS_W{1'b0}};
			svc_recv_count      <= {DMA_BEATS_W{1'b0}};
			m_buf_state0        <= MBUF_FREE;
			m_buf_state1        <= MBUF_FREE;
			m_buf_id0           <= 30'd0;
			m_buf_id1           <= 30'd0;
			next_wr_buf         <= 1'b0;
			exp_req_buf         <= 1'b0;
			exp_req_id          <= 30'd0;
			exp_active_buf      <= 1'b0;
			exp_active_id       <= 30'd0;
			exp_row_idx         <= {A_AW{1'b0}};
			exp_col_idx         <= {B_LW{1'b0}};
			exp_row_data        <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			exp_row_valid       <= 1'b0;
			exp_row_fetch_pending <= 1'b0;
			exp_fetch_row_idx   <= {A_AW{1'b0}};
			irq_r               <= 1'b0;
		end else if (clear) begin
			mem_done_valid      <= 1'b0;
			mem_done_id         <= 32'd0;
			mem_done_seq        <= 16'd0;
			mem_done_err        <= 1'b0;
			load_done_valid     <= 1'b0;
			load_done_id        <= 32'd0;
			load_done_side      <= 1'b0;
			load_done_buf       <= 1'b0;
			load_done_local_off <= 10'd0;
			load_done_ext_off   <= 10'd0;
			miss_done_valid     <= 1'b0;
			miss_done_id        <= 32'd0;
			miss_done_err       <= 1'b0;
			md_resp_valid       <= 1'b0;
			md_resp             <= 32'd0;
			a_mem_wr_en         <= 1'b0;
			b_mem_wr_en         <= 1'b0;
			csr_a_base_lo_we    <= 1'b0;
			csr_a_base_hi_we    <= 1'b0;
			csr_b_base_lo_we    <= 1'b0;
			csr_b_base_hi_we    <= 1'b0;
			csr_cfg_wdata16     <= 16'd0;
			csr_quant_commit_we <= 1'b0;
			csr_quant_mode_wdata <= `PT_QGRAN_PER_TENSOR;
			csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
			qcfg_active_id      <= 32'd0;
			qcfg_expect_cnt     <= {QCFG_CNT_W{1'b0}};
			qcfg_recv_cnt       <= {QCFG_CNT_W{1'b0}};
			qcfg_shadow_mode    <= `PT_QGRAN_PER_TENSOR;
			qcfg_shadow_inv_scale <= {MAX_DIM{32'h0001_0000}};
			a_wr_buf_sel        <= 1'b0;
			b_wr_buf_sel        <= 1'b0;
			svc_is_miss         <= 1'b0;
			svc_id              <= 32'd0;
			svc_seq             <= 16'd0;
			svc_need_a          <= 1'b0;
			svc_need_b          <= 1'b0;
			svc_a_off           <= 10'd0;
			svc_b_off           <= 10'd0;
			svc_is_b            <= 1'b0;
			svc_buf_sel         <= 1'b0;
			svc_ext_off         <= 10'd0;
			svc_row_base        <= 8'd0;
			svc_total_beats     <= {DMA_BEATS_W{1'b0}};
			svc_recv_count      <= {DMA_BEATS_W{1'b0}};
			m_buf_state0        <= MBUF_FREE;
			m_buf_state1        <= MBUF_FREE;
			m_buf_id0           <= 30'd0;
			m_buf_id1           <= 30'd0;
			next_wr_buf         <= 1'b0;
			exp_req_buf         <= 1'b0;
			exp_req_id          <= 30'd0;
			exp_active_buf      <= 1'b0;
			exp_active_id       <= 30'd0;
			exp_row_idx         <= {A_AW{1'b0}};
			exp_col_idx         <= {B_LW{1'b0}};
			exp_row_data        <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			exp_row_valid       <= 1'b0;
			exp_row_fetch_pending <= 1'b0;
			exp_fetch_row_idx   <= {A_AW{1'b0}};
			irq_r               <= 1'b0;
		end else begin
			mem_done_valid      <= 1'b0;
			load_done_valid     <= 1'b0;
			miss_done_valid     <= 1'b0;
			md_resp_valid       <= 1'b0;
			irq_r               <= 1'b0;
			a_mem_wr_en         <= 1'b0;
			b_mem_wr_en         <= 1'b0;
			csr_a_base_lo_we    <= 1'b0;
			csr_a_base_hi_we    <= 1'b0;
			csr_b_base_lo_we    <= 1'b0;
			csr_b_base_hi_we    <= 1'b0;
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

			if (exp_row_fetch_pending) begin
				exp_row_data          <= exp_rd_data;
				exp_row_valid         <= 1'b1;
				exp_row_fetch_pending <= 1'b0;
				exp_row_idx           <= exp_fetch_row_idx;
				exp_col_idx           <= {B_LW{1'b0}};
			end

			case (exec_state)
				ST_IDLE: begin
					if (miss_req_valid) begin
						svc_is_miss <= 1'b1;
						svc_id      <= miss_req_id;
						svc_seq     <= 16'd0;
						svc_need_a  <= miss_req_need_a;
						svc_need_b  <= miss_req_need_b;
						svc_a_off   <= miss_req_a_off;
						svc_b_off   <= miss_req_b_off;
						svc_recv_count <= {DMA_BEATS_W{1'b0}};
						if (miss_req_need_a) begin
							svc_is_b        <= 1'b0;
							svc_buf_sel     <= a_wr_buf_sel;
							svc_ext_off     <= miss_req_a_off;
							svc_row_base    <= miss_req_a_off[7:0] >> A_DIM_SHIFT;
							svc_total_beats <= A_ELEMS[DMA_BEATS_W-1:0];
						end else begin
							svc_is_b        <= 1'b1;
							svc_buf_sel     <= b_wr_buf_sel;
							svc_ext_off     <= miss_req_b_off;
							svc_row_base    <= miss_req_b_off[7:0] >> B_DIM_SHIFT;
							svc_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
						end
					end else if (mem_cmd_valid) begin
						case (mem_cmd_kind)
							`PT_MEM_KIND_CFG: begin
								csr_cfg_wdata16 <= mem_cmd_inst[15:0];
								case (mem_cmd_inst[27:24])
									`PT_CFG_A_BASE_LO: csr_a_base_lo_we <= 1'b1;
									`PT_CFG_A_BASE_HI: csr_a_base_hi_we <= 1'b1;
									`PT_CFG_B_BASE_LO: csr_b_base_lo_we <= 1'b1;
									`PT_CFG_B_BASE_HI: csr_b_base_hi_we <= 1'b1;
									default: begin
									end
								endcase
								md_resp       <= pack_resp(1'b0, 1'b0, mem_cmd_id);
								md_resp_valid <= 1'b1;
								mem_done_valid <= 1'b1;
								mem_done_id    <= mem_cmd_id;
								mem_done_seq   <= mem_cmd_seq;
								mem_done_err   <= 1'b0;
							end

							`PT_MEM_KIND_REJECT: begin
								md_resp       <= pack_resp(1'b1, 1'b0, mem_cmd_id);
								md_resp_valid <= 1'b1;
								mem_done_valid <= 1'b1;
								mem_done_id    <= mem_cmd_id;
								mem_done_seq   <= mem_cmd_seq;
								mem_done_err   <= 1'b1;
								irq_r          <= 1'b1;
							end

							`PT_MEM_KIND_QCFG_HDR: begin
								if (!qcfg_hdr_ok || qcfg_hdr_err || (qcfg_hdr_cnt == {QCFG_CNT_W{1'b0}})) begin
									md_resp       <= pack_resp(1'b1, 1'b0, mem_cmd_id);
									md_resp_valid <= 1'b1;
									mem_done_valid <= 1'b1;
									mem_done_id    <= mem_cmd_id;
									mem_done_seq   <= mem_cmd_seq;
									mem_done_err   <= 1'b1;
									irq_r          <= 1'b1;
								end else begin
									qcfg_active_id      <= mem_cmd_id;
									qcfg_expect_cnt     <= qcfg_hdr_cnt;
									qcfg_recv_cnt       <= {QCFG_CNT_W{1'b0}};
									qcfg_shadow_mode    <= cmd_qcfg_gran;
									qcfg_shadow_inv_scale <= csr_quant_inv_scale;
								end
							end

							`PT_MEM_KIND_QCFG_PAYLOAD: begin
								if (qcfg_expect_cnt == {QCFG_CNT_W{1'b0}}) begin
									md_resp       <= pack_resp(1'b1, 1'b0, mem_cmd_id);
									md_resp_valid <= 1'b1;
									mem_done_valid <= 1'b1;
									mem_done_id    <= mem_cmd_id;
									mem_done_seq   <= mem_cmd_seq;
									mem_done_err   <= 1'b1;
									irq_r          <= 1'b1;
								end else if (mem_cmd_id != qcfg_active_id) begin
									md_resp       <= pack_resp(1'b1, 1'b0, qcfg_active_id);
									md_resp_valid <= 1'b1;
									mem_done_valid <= 1'b1;
									mem_done_id    <= qcfg_active_id;
									mem_done_seq   <= mem_cmd_seq;
									mem_done_err   <= 1'b1;
									qcfg_expect_cnt <= {QCFG_CNT_W{1'b0}};
									qcfg_recv_cnt   <= {QCFG_CNT_W{1'b0}};
									irq_r          <= 1'b1;
								end else begin
									qcfg_shadow_inv_scale[qcfg_recv_cnt*32 +: 32] <= mem_cmd_inst;
									if ((qcfg_recv_cnt + 1'b1) >= qcfg_expect_cnt) begin
										csr_quant_mode_wdata <= qcfg_shadow_mode;
										for (ri = 0; ri < MAX_DIM; ri = ri + 1) begin
											if (ri == qcfg_recv_cnt) begin
												csr_quant_inv_scale_wdata[ri*32 +: 32] <= mem_cmd_inst;
											end else begin
												csr_quant_inv_scale_wdata[ri*32 +: 32] <= qcfg_shadow_inv_scale[ri*32 +: 32];
											end
										end
										csr_quant_commit_we <= 1'b1;
										md_resp       <= pack_resp(1'b0, 1'b0, qcfg_active_id);
										md_resp_valid <= 1'b1;
										mem_done_valid <= 1'b1;
										mem_done_id    <= qcfg_active_id;
										mem_done_seq   <= mem_cmd_seq;
										mem_done_err   <= 1'b0;
										qcfg_expect_cnt <= {QCFG_CNT_W{1'b0}};
										qcfg_recv_cnt   <= {QCFG_CNT_W{1'b0}};
									end else begin
										qcfg_recv_cnt <= qcfg_recv_cnt + 1'b1;
									end
								end
							end

							`PT_MEM_KIND_LOAD: begin
								if (!(cmd_load_need_a || cmd_load_need_b)) begin
									md_resp       <= pack_resp(1'b1, 1'b0, mem_cmd_id);
									md_resp_valid <= 1'b1;
									mem_done_valid <= 1'b1;
									mem_done_id    <= mem_cmd_id;
									mem_done_seq   <= mem_cmd_seq;
									mem_done_err   <= 1'b1;
									irq_r          <= 1'b1;
								end else begin
									svc_is_miss <= 1'b0;
									svc_id      <= mem_cmd_id;
									svc_seq     <= mem_cmd_seq;
									svc_need_a  <= cmd_load_need_a;
									svc_need_b  <= cmd_load_need_b;
									svc_a_off   <= cmd_load_a_off;
									svc_b_off   <= cmd_load_b_off;
									svc_recv_count <= {DMA_BEATS_W{1'b0}};
									if (cmd_load_need_a) begin
										svc_is_b        <= 1'b0;
										svc_buf_sel     <= a_wr_buf_sel;
										svc_ext_off     <= cmd_load_a_off;
										svc_row_base    <= cmd_load_a_off[7:0] >> A_DIM_SHIFT;
										svc_total_beats <= A_ELEMS[DMA_BEATS_W-1:0];
									end else begin
										svc_is_b        <= 1'b1;
										svc_buf_sel     <= b_wr_buf_sel;
										svc_ext_off     <= cmd_load_b_off;
										svc_row_base    <= cmd_load_b_off[7:0] >> B_DIM_SHIFT;
										svc_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
									end
								end
							end

							default: begin
								md_resp       <= pack_resp(1'b1, 1'b0, mem_cmd_id);
								md_resp_valid <= 1'b1;
								mem_done_valid <= 1'b1;
								mem_done_id    <= mem_cmd_id;
								mem_done_seq   <= mem_cmd_seq;
								mem_done_err   <= 1'b1;
								irq_r          <= 1'b1;
							end
						endcase
					end
				end

				ST_DMA_REQ: begin
					if (dma_req_ready) begin
						svc_recv_count <= {DMA_BEATS_W{1'b0}};
					end
				end

				ST_DMA_RECV: begin
					if (dma_error || dma_tuser_mismatch) begin
						if (svc_is_miss) begin
							miss_done_valid <= 1'b1;
							miss_done_id    <= svc_id;
							miss_done_err   <= 1'b1;
							md_resp         <= pack_resp(1'b1, 1'b0, svc_id);
							md_resp_valid   <= 1'b1;
						end else begin
							mem_done_valid <= 1'b1;
							mem_done_id    <= svc_id;
							mem_done_seq   <= svc_seq;
							mem_done_err   <= 1'b1;
							md_resp        <= pack_resp(1'b1, 1'b0, svc_id);
							md_resp_valid  <= 1'b1;
						end
						irq_r <= 1'b1;
					end else if (s_axis_tvalid) begin
						if (!svc_is_b) begin
							a_mem_wr_en   <= 1'b1;
							a_mem_wr_buf  <= svc_buf_sel;
							a_mem_wr_lane <= dma_a_row[A_LW-1:0];
							a_mem_wr_addr <= svc_row_base[A_AW-1:0] + dma_a_col[A_AW-1:0];
							a_mem_wr_data <= s_axis_tdata;
						end else begin
							b_mem_wr_en   <= 1'b1;
							b_mem_wr_buf  <= svc_buf_sel;
							b_mem_wr_lane <= dma_b_col[B_LW-1:0];
							b_mem_wr_addr <= svc_row_base[B_AW-1:0] + dma_b_row[B_AW-1:0];
							b_mem_wr_data <= s_axis_tdata;
						end
						svc_recv_count <= svc_recv_count + 1'b1;
						if ((svc_recv_count + 1'b1) >= svc_total_beats) begin
							load_done_valid     <= 1'b1;
							load_done_id        <= svc_id;
							load_done_side      <= svc_is_b ? 1'b1 : 1'b0;
							load_done_buf       <= svc_buf_sel;
							load_done_local_off <= svc_is_b ? make_b_local_off(svc_buf_sel, svc_row_base)
							                                 : make_a_local_off(svc_buf_sel, svc_row_base);
							load_done_ext_off   <= svc_ext_off;
							if (!svc_is_b) begin
								a_wr_buf_sel <= ~a_wr_buf_sel;
								if (svc_need_b) begin
									svc_is_b        <= 1'b1;
									svc_buf_sel     <= b_wr_buf_sel;
									svc_ext_off     <= svc_b_off;
									svc_row_base    <= svc_b_off[7:0] >> B_DIM_SHIFT;
									svc_total_beats <= B_ELEMS[DMA_BEATS_W-1:0];
									svc_recv_count  <= {DMA_BEATS_W{1'b0}};
								end else begin
									if (svc_is_miss) begin
										miss_done_valid <= 1'b1;
										miss_done_id    <= svc_id;
										miss_done_err   <= 1'b0;
									end else begin
										mem_done_valid <= 1'b1;
										mem_done_id    <= svc_id;
										mem_done_seq   <= svc_seq;
										mem_done_err   <= 1'b0;
										md_resp        <= pack_resp(1'b0, 1'b0, svc_id);
										md_resp_valid  <= 1'b1;
									end
								end
							end else begin
								b_wr_buf_sel <= ~b_wr_buf_sel;
								if (svc_is_miss) begin
									miss_done_valid <= 1'b1;
									miss_done_id    <= svc_id;
									miss_done_err   <= 1'b0;
								end else begin
									mem_done_valid <= 1'b1;
									mem_done_id    <= svc_id;
									mem_done_seq   <= svc_seq;
									mem_done_err   <= 1'b0;
									md_resp        <= pack_resp(1'b0, 1'b0, svc_id);
									md_resp_valid  <= 1'b1;
								end
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
					end
				end

				EXP_REQ: begin
					if (m_dma_req_ready) begin
						exp_active_buf <= exp_req_buf;
						exp_active_id  <= exp_req_id;
						exp_row_idx    <= {A_AW{1'b0}};
						exp_col_idx    <= {B_LW{1'b0}};
						exp_row_data   <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
						exp_row_valid  <= 1'b0;
						exp_row_fetch_pending <= 1'b0;
						exp_fetch_row_idx <= {A_AW{1'b0}};
						if (exp_req_buf) begin
							m_buf_state1 <= MBUF_EXPORTING;
						end else begin
							m_buf_state0 <= MBUF_EXPORTING;
						end
					end
				end

				EXP_STREAM: begin
					if (exp_row_req) begin
						exp_row_fetch_pending <= 1'b1;
						exp_fetch_row_idx     <= exp_req_row_addr;
					end
					if (exp_fire) begin
						if (exp_last_beat) begin
							exp_row_valid <= 1'b0;
						end else if (exp_col_idx == (GEMM_Y_DIM - 1)) begin
							exp_row_valid <= 1'b0;
							exp_col_idx   <= {B_LW{1'b0}};
						end else begin
							exp_col_idx <= exp_col_idx + 1'b1;
						end
					end
				end

				EXP_WAIT_DONE: begin
					if (m_dma_done || m_dma_error) begin
						exp_row_valid         <= 1'b0;
						exp_row_fetch_pending <= 1'b0;
						if (exp_active_buf) begin
							m_buf_state1 <= MBUF_FREE;
						end else begin
							m_buf_state0 <= MBUF_FREE;
						end
					end
				end
			endcase

			if (exp_dma_err_fire) begin
				md_resp       <= exp_err_resp;
				md_resp_valid <= 1'b1;
				irq_r         <= 1'b1;
			end
		end
	end

	wire _unused_ok = &{1'b0, dma_done};

endmodule
`else
module PT_MD;
endmodule
`endif
