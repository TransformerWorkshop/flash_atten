`include "param.vh"

module PT_MD_V3 #(
	parameter DATA_WIDTH   = 32,
	parameter ELEM_WIDTH   = 8,
	parameter PACK_LANES   = 4,
	parameter GEMM_X_DIM   = 4,
	parameter GEMM_Y_DIM   = 4,
	parameter DMA_BEATS_W  = 16,
	parameter A_BANK_DEPTH = 16,
	parameter B_BANK_DEPTH = 16,
	parameter M_BANK_DEPTH = 16,
	parameter A_LOAD_LANES = GEMM_X_DIM,
	parameter B_LOAD_LANES = GEMM_Y_DIM,
	parameter M_EXPORT_LANES = GEMM_Y_DIM
) (
	input  wire                       clk,
	input  wire                       rstn,
	input  wire                       clear,
	input  wire                       md_cmd_valid,
	output wire                       md_cmd_ready,
	input  wire [`PT_MEM_KIND_W-1:0]  md_cmd_kind,
	input  wire [`INST_WIDTH-1:0]     md_cmd_inst,
	input  wire [31:0]                md_cmd_id,
	output reg                        md_cmd_resp_valid,
	output reg  [31:0]                md_cmd_resp,
	output reg                        md_cmd_irq,
	output reg                        md_async_resp_valid,
	output reg  [31:0]                md_async_resp,
	output reg                        md_async_irq,
	input  wire                       fill_req_valid,
	output wire                       fill_req_ready,
	input  wire [`PT_DMA_KIND_W-1:0]  fill_req_kind,
	input  wire [31:0]                fill_req_id,
	input  wire [`PT_LOCAL_ADDR_W-1:0] fill_req_local_base,
	input  wire [`PT_SIZE_W-1:0]      fill_req_len,
	input  wire [3:0]                 fill_req_m_tiles,
	input  wire [3:0]                 fill_req_n_tiles,
	input  wire [3:0]                 fill_req_k_tiles,
	output reg                        fill_done_valid,
	output reg  [`PT_DMA_KIND_W-1:0]  fill_done_kind,
	output reg  [31:0]                fill_done_id,
	output reg                        fill_done_err,
	input  wire                       s_axis_tvalid,
	input  wire [(((A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES)*DATA_WIDTH)-1:0]      s_axis_tdata,
	input  wire [1:0]                 s_axis_tuser,
	output wire                       s_axis_tready,
	output wire                       dma_req_valid,
	input  wire                       dma_req_ready,
	output wire [`PT_DMA_KIND_W-1:0]  dma_req_kind,
	output wire [31:0]                dma_req_id,
	input  wire                       dma_error,
	output reg                        a_mem_wr_en,
	output reg                        a_mem_wr_buf,
	output reg  [GEMM_X_DIM-1:0]      a_mem_wr_mask,
	output reg  [(((A_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(A_BANK_DEPTH * GEMM_X_DIM))-1:0] a_mem_wr_addr,
	output reg  [GEMM_X_DIM*DATA_WIDTH-1:0]      a_mem_wr_data,
	output reg                        b_mem_wr_en,
	output reg                        b_mem_wr_buf,
	output reg  [GEMM_Y_DIM-1:0]      b_mem_wr_mask,
	output reg  [(((B_BANK_DEPTH * GEMM_Y_DIM) <= 1) ? 1 : $clog2(B_BANK_DEPTH * GEMM_Y_DIM))-1:0] b_mem_wr_addr,
	output reg  [GEMM_Y_DIM*DATA_WIDTH-1:0]      b_mem_wr_data,
	input  wire                       m_alloc_take,
	output wire                       m_alloc_ready,
	output wire                       m_alloc_buf,
	output wire                       m_buf0_single_output,
	output wire                       m_buf1_single_output,
	input  wire                       ce_resp_valid,
	input  wire [31:0]                ce_resp,
	input  wire [`PT_SIZE_W-1:0]      ce_resp_row_chunk_count,
	input  wire                       ce_resp_single_output,
	output wire                       m_dma_req_valid,
	input  wire                       m_dma_req_ready,
	output wire [31:0]                m_dma_req_id,
	output wire                       m_dma_req_buf,
	output wire [DMA_BEATS_W-1:0]     m_dma_req_beats,
	input  wire                       m_dma_done,
	input  wire                       m_dma_error,
	output wire                       m_axis_tvalid,
	input  wire                       m_axis_tready,
	output wire [M_EXPORT_LANES*DATA_WIDTH-1:0]      m_axis_tdata,
	output wire [M_EXPORT_LANES*DATA_WIDTH/8-1:0]    m_axis_tstrb,
	output wire                       m_axis_tlast,
	output wire                       m_axis_tkeep,
	output wire                       m_axis_tid,
	output wire                       m_axis_tdest,
	output wire [1:0]                 m_axis_tuser,
	output wire                       exp_rd_en,
	output wire                       exp_rd_buf,
	output wire [(((M_BANK_DEPTH * GEMM_X_DIM) <= 1) ? 1 : $clog2(M_BANK_DEPTH * GEMM_X_DIM))-1:0] exp_rd_addr,
	input  wire [GEMM_Y_DIM*DATA_WIDTH-1:0] exp_rd_data,
	input  wire [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale,
	output reg                        csr_a_base_lo_we,
	output reg                        csr_a_base_hi_we,
	output reg                        csr_b_base_lo_we,
	output reg                        csr_b_base_hi_we,
	output reg  [15:0]                csr_cfg_wdata16,
	output reg                        csr_quant_commit_we,
	output reg  [2:0]                 csr_quant_mode_wdata,
	output reg  [((GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM)*32-1:0] csr_quant_inv_scale_wdata
);

	localparam integer A_LW = (GEMM_X_DIM <= 1) ? 1 : $clog2(GEMM_X_DIM);
	localparam integer B_LW = (GEMM_Y_DIM <= 1) ? 1 : $clog2(GEMM_Y_DIM);
	localparam integer A_DEPTH = A_BANK_DEPTH * GEMM_X_DIM;
	localparam integer B_DEPTH = B_BANK_DEPTH * GEMM_Y_DIM;
	localparam integer M_DEPTH = M_BANK_DEPTH * GEMM_X_DIM;
	localparam integer A_AW = (A_DEPTH <= 1) ? 1 : $clog2(A_DEPTH);
	localparam integer B_AW = (B_DEPTH <= 1) ? 1 : $clog2(B_DEPTH);
	localparam integer M_AW = (M_DEPTH <= 1) ? 1 : $clog2(M_DEPTH);
	localparam integer LOAD_STREAM_LANES = (A_LOAD_LANES >= B_LOAD_LANES) ? A_LOAD_LANES : B_LOAD_LANES;
	localparam integer MAX_DIM = (GEMM_X_DIM >= GEMM_Y_DIM) ? GEMM_X_DIM : GEMM_Y_DIM;
	localparam integer QCFG_CNT_W = (MAX_DIM <= 1) ? 1 : $clog2(MAX_DIM + 1);
	localparam integer A_DIM_SHIFT = $clog2((GEMM_X_DIM <= 0) ? 1 : GEMM_X_DIM);
	localparam integer B_DIM_SHIFT = $clog2((GEMM_Y_DIM <= 0) ? 1 : GEMM_Y_DIM);
	localparam integer K_WORDS_PER_TILE = (PACK_LANES <= 1) ? GEMM_X_DIM : (GEMM_X_DIM / PACK_LANES);
	localparam integer A_LOAD_CHUNKS_PER_COL = (GEMM_X_DIM + A_LOAD_LANES - 1) / A_LOAD_LANES;
	localparam integer B_LOAD_CHUNKS_PER_ROW = (GEMM_Y_DIM + B_LOAD_LANES - 1) / B_LOAD_LANES;
	localparam integer EXP_PACKED_WORDS_PER_ROW = (PACK_LANES <= 1) ? GEMM_Y_DIM : (GEMM_Y_DIM / PACK_LANES);
	localparam integer EXP_ROWS_PER_BEAT = (PACK_LANES <= 1) ? (M_EXPORT_LANES / GEMM_Y_DIM) :
	                                       (M_EXPORT_LANES / EXP_PACKED_WORDS_PER_ROW);
	localparam integer EXP_ROW_FILL_W = (EXP_ROWS_PER_BEAT <= 1) ? 1 : $clog2(EXP_ROWS_PER_BEAT + 1);
	localparam [31:0] A_LOAD_LANES_U32 = A_LOAD_LANES;
	localparam [31:0] B_LOAD_LANES_U32 = B_LOAD_LANES;
	localparam [31:0] EXP_ROWS_PER_BEAT_U32 = EXP_ROWS_PER_BEAT;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_CFG          = 2'd0;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_QCFG_HDR     = 2'd1;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_QCFG_PAYLOAD = 2'd2;
	localparam [`PT_MEM_KIND_W-1:0] MEM_KIND_REJECT       = 2'd3;
	localparam [1:0] FILL_IDLE = 2'd0;
	localparam [1:0] FILL_REQ  = 2'd1;
	localparam [1:0] FILL_RECV = 2'd2;
	localparam [1:0] MBUF_FREE      = 2'd0;
	localparam [1:0] MBUF_EXEC      = 2'd1;
	localparam [1:0] MBUF_READY     = 2'd2;
	localparam [1:0] MBUF_EXPORTING = 2'd3;
	localparam [1:0] EXP_IDLE      = 2'd0;
	localparam [1:0] EXP_REQ       = 2'd1;
	localparam [1:0] EXP_STREAM    = 2'd2;
	localparam [1:0] EXP_WAIT_DONE = 2'd3;

	function [31:0] pack_resp;
		input err;
		input m_buf;
		input [31:0] id;
		begin
			pack_resp = {err, m_buf, id[29:0]};
		end
	endfunction

	function is_pow2;
		input integer value;
		begin
			is_pow2 = (value > 0) ? (((value & (value - 1)) == 0) ? 1'b1 : 1'b0) : 1'b0;
		end
	endfunction

	function integer min_int;
		input integer lhs;
		input integer rhs;
		begin
			min_int = (lhs < rhs) ? lhs : rhs;
		end
	endfunction

	function [EXP_PACKED_WORDS_PER_ROW*DATA_WIDTH-1:0] pack_export_row_words;
		input [GEMM_Y_DIM*DATA_WIDTH-1:0] row_data;
		integer word_idx;
		integer lane_idx;
		reg [DATA_WIDTH-1:0] packed_word;
		begin
			pack_export_row_words = {EXP_PACKED_WORDS_PER_ROW*DATA_WIDTH{1'b0}};
			for (word_idx = 0; word_idx < EXP_PACKED_WORDS_PER_ROW; word_idx = word_idx + 1) begin
				packed_word = {DATA_WIDTH{1'b0}};
				for (lane_idx = 0; lane_idx < PACK_LANES; lane_idx = lane_idx + 1) begin
					packed_word[(lane_idx * ELEM_WIDTH) +: ELEM_WIDTH] =
						row_data[((word_idx * PACK_LANES) + lane_idx) * DATA_WIDTH +: ELEM_WIDTH];
				end
				pack_export_row_words[word_idx*DATA_WIDTH +: DATA_WIDTH] = packed_word;
			end
		end
	endfunction

// synthesis translate_off
	`ifndef SYNTHESIS
		initial begin
			if (!is_pow2(GEMM_X_DIM) || !is_pow2(GEMM_Y_DIM)) begin
				$fatal(1, "PT_MD_V3 requires power-of-two GEMM_X_DIM/GEMM_Y_DIM, got %0d x %0d", GEMM_X_DIM, GEMM_Y_DIM);
			end
			if ((PACK_LANES <= 0) || ((GEMM_X_DIM % PACK_LANES) != 0)) begin
				$fatal(1, "PT_MD_V3 requires GEMM_X_DIM %% PACK_LANES == 0, got X=%0d lanes=%0d", GEMM_X_DIM, PACK_LANES);
			end
			if ((A_LOAD_LANES <= 0) || (A_LOAD_LANES > GEMM_X_DIM)) begin
				$fatal(1, "PT_MD_V2 requires 0 < A_LOAD_LANES <= GEMM_X_DIM, got %0d for X=%0d", A_LOAD_LANES, GEMM_X_DIM);
			end
			if ((GEMM_X_DIM % A_LOAD_LANES) != 0) begin
				$fatal(1, "PT_MD_V2 currently requires GEMM_X_DIM %% A_LOAD_LANES == 0, got X=%0d lanes=%0d", GEMM_X_DIM, A_LOAD_LANES);
			end
			if ((B_LOAD_LANES <= 0) || (B_LOAD_LANES > GEMM_Y_DIM)) begin
				$fatal(1, "PT_MD_V2 requires 0 < B_LOAD_LANES <= GEMM_Y_DIM, got %0d for Y=%0d", B_LOAD_LANES, GEMM_Y_DIM);
			end
			if ((GEMM_Y_DIM % B_LOAD_LANES) != 0) begin
				$fatal(1, "PT_MD_V2 currently requires GEMM_Y_DIM %% B_LOAD_LANES == 0, got Y=%0d lanes=%0d", GEMM_Y_DIM, B_LOAD_LANES);
			end
			if ((M_EXPORT_LANES <= 0) || (M_EXPORT_LANES > GEMM_Y_DIM)) begin
				$fatal(1, "PT_MD_V2 requires 0 < M_EXPORT_LANES <= GEMM_Y_DIM, got %0d for Y=%0d", M_EXPORT_LANES, GEMM_Y_DIM);
			end
			if ((GEMM_Y_DIM % M_EXPORT_LANES) != 0) begin
				$fatal(1, "PT_MD_V2 currently requires GEMM_Y_DIM %% M_EXPORT_LANES == 0, got Y=%0d lanes=%0d", GEMM_Y_DIM, M_EXPORT_LANES);
			end
			if ((PACK_LANES > 1) && ((GEMM_Y_DIM % PACK_LANES) != 0)) begin
				$fatal(1, "PT_MD_V3 requires GEMM_Y_DIM %% PACK_LANES == 0 for packed export, got Y=%0d lanes=%0d", GEMM_Y_DIM, PACK_LANES);
			end
			if ((M_EXPORT_LANES % EXP_PACKED_WORDS_PER_ROW) != 0) begin
				$fatal(1, "PT_MD_V3 requires M_EXPORT_LANES %% EXP_PACKED_WORDS_PER_ROW == 0, got export=%0d packed_row=%0d", M_EXPORT_LANES, EXP_PACKED_WORDS_PER_ROW);
			end
		end
	`endif
// synthesis translate_on

	assign md_cmd_ready = 1'b1;

	wire [3:0] cmd_qcfg_cmd = md_cmd_inst[`PT_QCFG_CMD_H:`PT_QCFG_CMD_L];
	wire [1:0] cmd_qcfg_qtype = md_cmd_inst[`PT_QCFG_QTYPE_H:`PT_QCFG_QTYPE_L];
	wire [2:0] cmd_qcfg_gran = md_cmd_inst[`PT_QCFG_GRAN_H:`PT_QCFG_GRAN_L];

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

	reg [31:0] qcfg_active_id_r;
	reg [QCFG_CNT_W-1:0] qcfg_expect_cnt_r;
	reg [QCFG_CNT_W-1:0] qcfg_recv_cnt_r;
	reg [2:0] qcfg_shadow_mode_r;
	reg [MAX_DIM*32-1:0] qcfg_shadow_inv_scale_r;

	reg [1:0] fill_state_r, fill_state_n;
	reg [`PT_DMA_KIND_W-1:0] fill_kind_r;
	reg [31:0] fill_id_r;
	reg [`PT_LOCAL_ADDR_W-1:0] fill_local_base_r;
	reg [`PT_SIZE_W-1:0] fill_len_r;
	reg [`PT_SIZE_W-1:0] fill_recv_count_r;
	reg [`PT_SIZE_W-1:0] fill_recv_count_n;
	reg [3:0] fill_m_tiles_r, fill_n_tiles_r, fill_k_tiles_r;
	localparam integer FILL_ROW_W = (A_AW >= B_AW) ? A_AW : B_AW;
	reg [FILL_ROW_W-1:0] fill_row_base_r;
	reg fill_buf_sel_r;
	integer fill_a_row_base_int;
	integer fill_b_col_base_int;
	integer fill_a_valid_elems_int;
	integer fill_b_valid_elems_int;

	wire fill_is_a = (fill_kind_r == `PT_DMA_KIND_A);
	wire fill_is_bc = (fill_kind_r == `PT_DMA_KIND_B) || (fill_kind_r == `PT_DMA_KIND_C);
	wire fill_is_c = (fill_kind_r == `PT_DMA_KIND_C);
	wire [1:0] fill_expected_tuser = fill_is_a ? `PT_STREAM_KIND_A :
	                                 ((fill_kind_r == `PT_DMA_KIND_B) ? `PT_STREAM_KIND_B : `PT_STREAM_KIND_C);
	wire fill_tuser_mismatch = s_axis_tvalid && (s_axis_tuser != fill_expected_tuser);
	wire [`PT_SIZE_W-1:0] fill_remaining = (fill_len_r > fill_recv_count_r) ? (fill_len_r - fill_recv_count_r) : {`PT_SIZE_W{1'b0}};
	wire [31:0] fill_recv_count_u32 = {{(32-`PT_SIZE_W){1'b0}}, fill_recv_count_r};
	wire [31:0] fill_remaining_u32 = {{(32-`PT_SIZE_W){1'b0}}, fill_remaining};
	wire [31:0] fill_a_chunk_idx = fill_recv_count_u32 / A_LOAD_LANES;
	wire [31:0] fill_b_chunk_idx = fill_recv_count_u32 / B_LOAD_LANES;
	wire [31:0] fill_a_chunks_per_m_tile = fill_k_tiles_r * K_WORDS_PER_TILE * A_LOAD_CHUNKS_PER_COL;
	wire [31:0] fill_b_chunks_per_n_tile =
		fill_is_c ? (GEMM_Y_DIM * B_LOAD_CHUNKS_PER_ROW) :
		            (fill_k_tiles_r * K_WORDS_PER_TILE * B_LOAD_CHUNKS_PER_ROW);
	wire [31:0] fill_a_m_tile = (fill_a_chunks_per_m_tile == 0) ? 0 : (fill_a_chunk_idx / fill_a_chunks_per_m_tile);
	wire [31:0] fill_a_chunk_in_m_tile = (fill_a_chunks_per_m_tile == 0) ? 0 : (fill_a_chunk_idx % fill_a_chunks_per_m_tile);
	wire [31:0] fill_b_n_tile = (fill_b_chunks_per_n_tile == 0) ? 0 : (fill_b_chunk_idx / fill_b_chunks_per_n_tile);
	wire [31:0] fill_b_chunk_in_n_tile = (fill_b_chunks_per_n_tile == 0) ? 0 : (fill_b_chunk_idx % fill_b_chunks_per_n_tile);
	wire [31:0] fill_a_col = fill_a_chunk_in_m_tile / A_LOAD_CHUNKS_PER_COL;
	wire [31:0] fill_a_row_chunk = fill_a_chunk_in_m_tile % A_LOAD_CHUNKS_PER_COL;
	wire [31:0] fill_b_row = fill_b_chunk_in_n_tile / B_LOAD_CHUNKS_PER_ROW;
	wire [31:0] fill_b_col_chunk = fill_b_chunk_in_n_tile % B_LOAD_CHUNKS_PER_ROW;
	wire [31:0] fill_a_row_base = fill_a_row_chunk * A_LOAD_LANES;
	wire [31:0] fill_b_col_base = fill_b_col_chunk * B_LOAD_LANES;
	wire [31:0] fill_a_m_tile_row_offset = fill_a_m_tile * (fill_k_tiles_r * K_WORDS_PER_TILE);
	wire [31:0] fill_b_n_tile_row_offset =
		fill_is_c ? (fill_b_n_tile * GEMM_Y_DIM) :
		            (fill_b_n_tile * (fill_k_tiles_r * K_WORDS_PER_TILE));
	wire [31:0] fill_a_valid_elems = (fill_remaining_u32 < A_LOAD_LANES_U32) ? fill_remaining_u32 : A_LOAD_LANES_U32;
	wire [31:0] fill_b_valid_elems = (fill_remaining_u32 < B_LOAD_LANES_U32) ? fill_remaining_u32 : B_LOAD_LANES_U32;
	wire [31:0] fill_beat_elems = fill_is_a ? fill_a_valid_elems : fill_b_valid_elems;
	wire [`PT_SIZE_W-1:0] fill_beat_elems_size = fill_beat_elems[`PT_SIZE_W-1:0];
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] fill_local_elem = fill_req_local_base[`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L];
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] fill_req_a_row_base_full = fill_local_elem >> A_DIM_SHIFT;
	wire [`PT_LOCAL_ELEM_H:`PT_LOCAL_ELEM_L] fill_req_b_row_base_full = fill_local_elem >> B_DIM_SHIFT;
	wire [A_AW-1:0] fill_req_a_row_base = fill_req_a_row_base_full[A_AW-1:0];
	wire [B_AW-1:0] fill_req_b_row_base = fill_req_b_row_base_full[B_AW-1:0];

	assign fill_req_ready = (fill_state_r == FILL_IDLE);
	assign dma_req_valid  = (fill_state_r == FILL_REQ);
	assign dma_req_kind   = fill_kind_r;
	assign dma_req_id     = fill_id_r;
	assign s_axis_tready  = (fill_state_r == FILL_RECV);

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			fill_state_r <= FILL_IDLE;
		end else if (clear) begin
			fill_state_r <= FILL_IDLE;
		end else begin
			fill_state_r <= fill_state_n;
		end
	end

	always @(*) begin
		fill_state_n = fill_state_r;
		case (fill_state_r)
			FILL_IDLE: if (fill_req_valid) fill_state_n = FILL_REQ;
			FILL_REQ:  if (dma_req_ready) fill_state_n = FILL_RECV;
			FILL_RECV: begin
				if (dma_error || fill_tuser_mismatch) begin
					fill_state_n = FILL_IDLE;
				end else if (s_axis_tvalid && ((fill_recv_count_r + fill_beat_elems[`PT_SIZE_W-1:0]) >= fill_len_r)) begin
					fill_state_n = FILL_IDLE;
				end
			end
			default: fill_state_n = FILL_IDLE;
		endcase
	end

	reg [1:0] m_buf_state0_r, m_buf_state1_r;
	reg [1:0] m_buf_state0_n, m_buf_state1_n;
	reg [29:0] m_buf_id0_r, m_buf_id1_r;
	reg m_buf0_single_output_r, m_buf1_single_output_r;
	reg [`PT_SIZE_W-1:0] m_buf0_row_chunk_count_r, m_buf1_row_chunk_count_r;
	reg next_wr_buf_r;
	reg next_wr_buf_n;

	reg [1:0] exp_state_r, exp_state_n;
	reg exp_req_buf_r, exp_active_buf_r;
	reg exp_req_buf_n, exp_active_buf_n;
	reg [29:0] exp_req_id_r, exp_active_id_r;
	reg [29:0] exp_req_id_n, exp_active_id_n;
	reg [`PT_SIZE_W-1:0] exp_req_row_chunk_count_r, exp_active_row_chunk_count_r;
	reg [`PT_SIZE_W-1:0] exp_req_row_chunk_count_n, exp_active_row_chunk_count_n;
	reg [M_AW-1:0] exp_next_row_idx_r, exp_fetch_row_idx_r;
	reg [M_AW-1:0] exp_next_row_idx_n, exp_fetch_row_idx_n;
	reg [EXP_ROW_FILL_W-1:0] exp_fill_count_r;
	reg [EXP_ROW_FILL_W-1:0] exp_fill_count_n;
	reg [M_EXPORT_LANES*DATA_WIDTH-1:0] exp_beat_data_r;
	reg [M_EXPORT_LANES*DATA_WIDTH-1:0] exp_beat_data_n;
	reg [M_EXPORT_LANES*DATA_WIDTH/8-1:0] exp_beat_strb_r;
	reg [M_EXPORT_LANES*DATA_WIDTH/8-1:0] exp_beat_strb_n;
	reg exp_beat_valid_r, exp_beat_last_r, exp_row_fetch_pending_r;
	reg exp_beat_valid_n, exp_beat_last_n, exp_row_fetch_pending_n;

	wire m_buf0_free = (m_buf_state0_r == MBUF_FREE);
	wire m_buf1_free = (m_buf_state1_r == MBUF_FREE);
	wire m_buf0_ready = (m_buf_state0_r == MBUF_READY);
	wire m_buf1_ready = (m_buf_state1_r == MBUF_READY);
	wire exp_has_ready = m_buf0_ready || m_buf1_ready;
	wire exp_pick_buf = (m_buf0_ready && m_buf1_ready) ? next_wr_buf_r : (m_buf1_ready ? 1'b1 : 1'b0);
	wire [29:0] exp_pick_id = exp_pick_buf ? m_buf_id1_r : m_buf_id0_r;
	wire [`PT_SIZE_W-1:0] exp_pick_row_chunks = exp_pick_buf ? m_buf1_row_chunk_count_r : m_buf0_row_chunk_count_r;
	wire [31:0] exp_next_row_idx_u32 = {{(32-M_AW){1'b0}}, exp_next_row_idx_r};
	wire [31:0] exp_fetch_row_idx_u32 = {{(32-M_AW){1'b0}}, exp_fetch_row_idx_r};
	wire [31:0] exp_active_row_chunks_u32 = {{(32-`PT_SIZE_W){1'b0}}, exp_active_row_chunk_count_r};
	wire [31:0] exp_req_row_chunk_count_u32 = {{(32-`PT_SIZE_W){1'b0}}, exp_req_row_chunk_count_r};
	wire [31:0] exp_req_beats_u32 =
		(exp_req_row_chunk_count_u32 == 0) ? 32'd0 :
		((exp_req_row_chunk_count_u32 + EXP_ROWS_PER_BEAT_U32 - 1'b1) / EXP_ROWS_PER_BEAT_U32);
	wire exp_fire = (exp_state_r == EXP_STREAM) && exp_beat_valid_r && m_axis_tready;
	wire exp_last_beat = exp_fire && exp_beat_last_r;
	wire [EXP_PACKED_WORDS_PER_ROW*DATA_WIDTH-1:0] exp_packed_row_data = pack_export_row_words(exp_rd_data);
	wire [EXP_ROW_FILL_W:0] exp_fill_count_next = exp_fill_count_r + 1'b1;
	wire exp_capture_last_row = (exp_fetch_row_idx_u32 == (exp_active_row_chunks_u32 - 1'b1));
	wire exp_capture_group_done =
		(exp_fill_count_next >= EXP_ROWS_PER_BEAT_U32[EXP_ROW_FILL_W:0]) || exp_capture_last_row;
	wire exp_prime_req = (exp_state_r == EXP_STREAM) &&
	                    !exp_beat_valid_r &&
	                    !exp_row_fetch_pending_r &&
	                    (exp_next_row_idx_u32 < exp_active_row_chunks_u32);
	wire exp_chain_req = (exp_state_r == EXP_STREAM) &&
	                    !exp_beat_valid_r &&
	                    exp_row_fetch_pending_r &&
	                    !exp_capture_group_done &&
	                    ((exp_fetch_row_idx_u32 + 1'b1) < exp_active_row_chunks_u32);
	wire exp_row_req = exp_prime_req || exp_chain_req;
	wire [M_AW-1:0] exp_req_row_addr = exp_chain_req ? (exp_fetch_row_idx_r + 1'b1) : exp_next_row_idx_r;

	always @(*) begin
		fill_a_row_base_int = fill_a_row_base;
		fill_b_col_base_int = fill_b_col_base;
		fill_a_valid_elems_int = fill_a_valid_elems;
		fill_b_valid_elems_int = fill_b_valid_elems;
	end
	assign m_alloc_ready = m_buf0_free || m_buf1_free;
	assign m_alloc_buf = m_buf0_free ? 1'b0 : 1'b1;
	assign m_buf0_single_output = m_buf0_single_output_r;
	assign m_buf1_single_output = m_buf1_single_output_r;

	assign m_dma_req_valid = (exp_state_r == EXP_REQ);
	assign m_dma_req_id    = {2'b00, exp_req_id_r};
	assign m_dma_req_buf   = exp_req_buf_r;
	assign m_dma_req_beats = exp_req_beats_u32[DMA_BEATS_W-1:0];
	assign exp_rd_en   = exp_row_req;
	assign exp_rd_buf  = exp_active_buf_r;
	assign exp_rd_addr = exp_req_row_addr;
	assign m_axis_tvalid = (exp_state_r == EXP_STREAM) && exp_beat_valid_r;
	assign m_axis_tdata  = exp_beat_data_r;
	assign m_axis_tstrb  = exp_beat_strb_r;
	assign m_axis_tlast  = exp_beat_valid_r && exp_beat_last_r;
	assign m_axis_tkeep  = 1'b1;
	assign m_axis_tid    = 1'b0;
	assign m_axis_tdest  = 1'b0;
	assign m_axis_tuser  = {1'b0, exp_active_buf_r};

	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			exp_state_r <= EXP_IDLE;
		end else if (clear) begin
			exp_state_r <= EXP_IDLE;
		end else begin
			exp_state_r <= exp_state_n;
		end
	end

	always @(*) begin
		exp_state_n = exp_state_r;
		case (exp_state_r)
			EXP_IDLE:      if (exp_has_ready) exp_state_n = EXP_REQ;
			EXP_REQ:       if (m_dma_req_ready) exp_state_n = EXP_STREAM;
			EXP_STREAM:    if (exp_fire && exp_last_beat) exp_state_n = EXP_WAIT_DONE;
			EXP_WAIT_DONE: if (m_dma_done || m_dma_error) exp_state_n = EXP_IDLE;
			default:       exp_state_n = EXP_IDLE;
		endcase
	end

	integer fi;
	always @(*) begin
		fill_recv_count_n = fill_recv_count_r;
		m_buf_state0_n = m_buf_state0_r;
		m_buf_state1_n = m_buf_state1_r;
		next_wr_buf_n = next_wr_buf_r;
		exp_req_buf_n = exp_req_buf_r;
		exp_req_id_n = exp_req_id_r;
		exp_req_row_chunk_count_n = exp_req_row_chunk_count_r;
		exp_active_buf_n = exp_active_buf_r;
		exp_active_id_n = exp_active_id_r;
		exp_active_row_chunk_count_n = exp_active_row_chunk_count_r;
		exp_next_row_idx_n = exp_next_row_idx_r;
		exp_fetch_row_idx_n = exp_fetch_row_idx_r;
		exp_fill_count_n = exp_fill_count_r;
		exp_beat_data_n = exp_beat_data_r;
		exp_beat_strb_n = exp_beat_strb_r;
		exp_beat_valid_n = exp_beat_valid_r;
		exp_beat_last_n = exp_beat_last_r;
		exp_row_fetch_pending_n = exp_row_fetch_pending_r;

		if (m_alloc_take && m_alloc_ready) begin
			if (m_alloc_buf) begin
				m_buf_state1_n = MBUF_EXEC;
			end else begin
				m_buf_state0_n = MBUF_EXEC;
			end
		end

		if ((fill_state_r == FILL_IDLE) && fill_req_valid && fill_req_ready) begin
			fill_recv_count_n = {`PT_SIZE_W{1'b0}};
		end

		if (fill_state_r == FILL_RECV) begin
			if (!(dma_error || fill_tuser_mismatch) && s_axis_tvalid) begin
				fill_recv_count_n = fill_recv_count_r + fill_beat_elems_size;
			end
		end

		if (ce_resp_valid) begin
			if (!ce_resp[31]) begin
				next_wr_buf_n = ~ce_resp[30];
				if (ce_resp[30]) begin
					m_buf_state1_n = MBUF_READY;
				end else begin
					m_buf_state0_n = MBUF_READY;
				end
			end else if (ce_resp[30]) begin
				m_buf_state1_n = MBUF_FREE;
			end else begin
				m_buf_state0_n = MBUF_FREE;
			end
		end

		if (exp_row_fetch_pending_r) begin
			exp_row_fetch_pending_n = exp_chain_req;
			exp_next_row_idx_n      = exp_fetch_row_idx_r + 1'b1;
			if (exp_chain_req) begin
				exp_fetch_row_idx_n = exp_fetch_row_idx_r + 1'b1;
			end
			for (fi = 0; fi < EXP_PACKED_WORDS_PER_ROW; fi = fi + 1) begin
				exp_beat_data_n[((exp_fill_count_r * EXP_PACKED_WORDS_PER_ROW) + fi)*DATA_WIDTH +: DATA_WIDTH] =
					exp_packed_row_data[fi*DATA_WIDTH +: DATA_WIDTH];
				exp_beat_strb_n[((exp_fill_count_r * EXP_PACKED_WORDS_PER_ROW) + fi)*(DATA_WIDTH/8) +: (DATA_WIDTH/8)] =
					{(DATA_WIDTH/8){1'b1}};
			end
			exp_fill_count_n = exp_fill_count_next[EXP_ROW_FILL_W-1:0];
			if (exp_capture_group_done) begin
				exp_beat_valid_n = 1'b1;
				exp_beat_last_n  = exp_capture_last_row;
			end
		end

		case (exp_state_r)
			EXP_IDLE: begin
				if (exp_has_ready) begin
					exp_req_buf_n = exp_pick_buf;
					exp_req_id_n  = exp_pick_id;
					exp_req_row_chunk_count_n = exp_pick_row_chunks;
				end
			end
			EXP_REQ: begin
				if (m_dma_req_ready) begin
					exp_active_buf_n = exp_req_buf_r;
					exp_active_id_n  = exp_req_id_r;
					exp_active_row_chunk_count_n = exp_req_row_chunk_count_r;
					exp_next_row_idx_n      = {M_AW{1'b0}};
					exp_fill_count_n        = {EXP_ROW_FILL_W{1'b0}};
					exp_beat_data_n         = {M_EXPORT_LANES*DATA_WIDTH{1'b0}};
					exp_beat_strb_n         = {M_EXPORT_LANES*DATA_WIDTH/8{1'b0}};
					exp_beat_valid_n        = 1'b0;
					exp_beat_last_n         = 1'b0;
					exp_row_fetch_pending_n = 1'b0;
					exp_fetch_row_idx_n     = {M_AW{1'b0}};
					if (exp_req_buf_r) begin
						m_buf_state1_n = MBUF_EXPORTING;
					end else begin
						m_buf_state0_n = MBUF_EXPORTING;
					end
				end
			end
			EXP_STREAM: begin
				if (exp_prime_req) begin
					exp_row_fetch_pending_n = 1'b1;
					exp_fetch_row_idx_n     = exp_req_row_addr;
				end else if (exp_fire) begin
					exp_beat_valid_n = 1'b0;
					if (!exp_beat_last_r) begin
						exp_beat_data_n  = {M_EXPORT_LANES*DATA_WIDTH{1'b0}};
						exp_beat_strb_n  = {M_EXPORT_LANES*DATA_WIDTH/8{1'b0}};
						exp_fill_count_n = {EXP_ROW_FILL_W{1'b0}};
						exp_beat_last_n  = 1'b0;
					end else begin
						exp_beat_last_n = 1'b0;
					end
				end
			end
			EXP_WAIT_DONE: begin
				if (m_dma_done || m_dma_error) begin
					exp_beat_valid_n        = 1'b0;
					exp_beat_last_n         = 1'b0;
					exp_row_fetch_pending_n = 1'b0;
					exp_fill_count_n        = {EXP_ROW_FILL_W{1'b0}};
					exp_beat_data_n         = {M_EXPORT_LANES*DATA_WIDTH{1'b0}};
					exp_beat_strb_n         = {M_EXPORT_LANES*DATA_WIDTH/8{1'b0}};
					if (exp_active_buf_r) begin
						m_buf_state1_n = MBUF_FREE;
					end else begin
						m_buf_state0_n = MBUF_FREE;
					end
				end
			end
			default: begin end
		endcase
	end

	integer ri;
	always @(posedge clk or negedge rstn) begin
		if (!rstn) begin
			md_cmd_resp_valid         <= 1'b0;
			md_cmd_resp               <= 32'd0;
			md_cmd_irq                <= 1'b0;
			md_async_resp_valid       <= 1'b0;
			md_async_resp             <= 32'd0;
			md_async_irq              <= 1'b0;
			fill_done_valid           <= 1'b0;
			fill_done_kind            <= {`PT_DMA_KIND_W{1'b0}};
			fill_done_id              <= 32'd0;
			fill_done_err             <= 1'b0;
			a_mem_wr_en               <= 1'b0;
			a_mem_wr_buf              <= 1'b0;
			a_mem_wr_mask             <= {GEMM_X_DIM{1'b0}};
			a_mem_wr_addr             <= {A_AW{1'b0}};
			a_mem_wr_data             <= {GEMM_X_DIM*DATA_WIDTH{1'b0}};
			b_mem_wr_en               <= 1'b0;
			b_mem_wr_buf              <= 1'b0;
			b_mem_wr_mask             <= {GEMM_Y_DIM{1'b0}};
			b_mem_wr_addr             <= {B_AW{1'b0}};
			b_mem_wr_data             <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			csr_a_base_lo_we          <= 1'b0;
			csr_a_base_hi_we          <= 1'b0;
			csr_b_base_lo_we          <= 1'b0;
			csr_b_base_hi_we          <= 1'b0;
			csr_cfg_wdata16           <= 16'd0;
			csr_quant_commit_we       <= 1'b0;
			csr_quant_mode_wdata      <= `PT_QGRAN_PER_TENSOR;
			csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
			qcfg_active_id_r          <= 32'd0;
			qcfg_expect_cnt_r         <= {QCFG_CNT_W{1'b0}};
			qcfg_recv_cnt_r           <= {QCFG_CNT_W{1'b0}};
			qcfg_shadow_mode_r        <= `PT_QGRAN_PER_TENSOR;
			qcfg_shadow_inv_scale_r   <= {MAX_DIM{32'h0001_0000}};
			fill_kind_r               <= {`PT_DMA_KIND_W{1'b0}};
			fill_id_r                 <= 32'd0;
			fill_local_base_r         <= {`PT_LOCAL_ADDR_W{1'b0}};
			fill_len_r                <= {`PT_SIZE_W{1'b0}};
			fill_recv_count_r         <= {`PT_SIZE_W{1'b0}};
			fill_m_tiles_r            <= `PT_TILES_1;
			fill_n_tiles_r            <= `PT_TILES_1;
			fill_k_tiles_r            <= `PT_TILES_1;
			fill_row_base_r           <= {FILL_ROW_W{1'b0}};
			fill_buf_sel_r            <= 1'b0;
			m_buf_state0_r            <= MBUF_FREE;
			m_buf_state1_r            <= MBUF_FREE;
			m_buf_id0_r               <= 30'd0;
			m_buf_id1_r               <= 30'd0;
			m_buf0_single_output_r    <= 1'b1;
			m_buf1_single_output_r    <= 1'b1;
			m_buf0_row_chunk_count_r  <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			m_buf1_row_chunk_count_r  <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			next_wr_buf_r             <= 1'b0;
			exp_req_buf_r             <= 1'b0;
			exp_req_id_r              <= 30'd0;
			exp_req_row_chunk_count_r <= {`PT_SIZE_W{1'b0}};
			exp_active_buf_r          <= 1'b0;
			exp_active_id_r           <= 30'd0;
			exp_active_row_chunk_count_r <= {`PT_SIZE_W{1'b0}};
			exp_next_row_idx_r        <= {M_AW{1'b0}};
			exp_fetch_row_idx_r       <= {M_AW{1'b0}};
			exp_fill_count_r          <= {EXP_ROW_FILL_W{1'b0}};
			exp_beat_data_r           <= {M_EXPORT_LANES*DATA_WIDTH{1'b0}};
			exp_beat_strb_r           <= {M_EXPORT_LANES*DATA_WIDTH/8{1'b0}};
			exp_beat_valid_r          <= 1'b0;
			exp_beat_last_r           <= 1'b0;
			exp_row_fetch_pending_r   <= 1'b0;
		end else if (clear) begin
			md_cmd_resp_valid         <= 1'b0;
			md_cmd_resp               <= 32'd0;
			md_cmd_irq                <= 1'b0;
			md_async_resp_valid       <= 1'b0;
			md_async_resp             <= 32'd0;
			md_async_irq              <= 1'b0;
			fill_done_valid           <= 1'b0;
			fill_done_kind            <= {`PT_DMA_KIND_W{1'b0}};
			fill_done_id              <= 32'd0;
			fill_done_err             <= 1'b0;
			a_mem_wr_en               <= 1'b0;
			a_mem_wr_mask             <= {GEMM_X_DIM{1'b0}};
			a_mem_wr_data             <= {GEMM_X_DIM*DATA_WIDTH{1'b0}};
			b_mem_wr_en               <= 1'b0;
			b_mem_wr_mask             <= {GEMM_Y_DIM{1'b0}};
			b_mem_wr_data             <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
			csr_a_base_lo_we          <= 1'b0;
			csr_a_base_hi_we          <= 1'b0;
			csr_b_base_lo_we          <= 1'b0;
			csr_b_base_hi_we          <= 1'b0;
			csr_cfg_wdata16           <= 16'd0;
			csr_quant_commit_we       <= 1'b0;
			csr_quant_mode_wdata      <= `PT_QGRAN_PER_TENSOR;
			csr_quant_inv_scale_wdata <= {MAX_DIM{32'h0001_0000}};
			qcfg_active_id_r          <= 32'd0;
			qcfg_expect_cnt_r         <= {QCFG_CNT_W{1'b0}};
			qcfg_recv_cnt_r           <= {QCFG_CNT_W{1'b0}};
			qcfg_shadow_mode_r        <= `PT_QGRAN_PER_TENSOR;
			qcfg_shadow_inv_scale_r   <= {MAX_DIM{32'h0001_0000}};
			fill_kind_r               <= {`PT_DMA_KIND_W{1'b0}};
			fill_id_r                 <= 32'd0;
			fill_local_base_r         <= {`PT_LOCAL_ADDR_W{1'b0}};
			fill_len_r                <= {`PT_SIZE_W{1'b0}};
			fill_recv_count_r         <= {`PT_SIZE_W{1'b0}};
			fill_m_tiles_r            <= `PT_TILES_1;
			fill_n_tiles_r            <= `PT_TILES_1;
			fill_k_tiles_r            <= `PT_TILES_1;
			fill_row_base_r           <= {FILL_ROW_W{1'b0}};
			fill_buf_sel_r            <= 1'b0;
			m_buf_state0_r            <= MBUF_FREE;
			m_buf_state1_r            <= MBUF_FREE;
			m_buf_id0_r               <= 30'd0;
			m_buf_id1_r               <= 30'd0;
			m_buf0_single_output_r    <= 1'b1;
			m_buf1_single_output_r    <= 1'b1;
			m_buf0_row_chunk_count_r  <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			m_buf1_row_chunk_count_r  <= GEMM_X_DIM[`PT_SIZE_W-1:0];
			next_wr_buf_r             <= 1'b0;
			exp_req_buf_r             <= 1'b0;
			exp_req_id_r              <= 30'd0;
			exp_req_row_chunk_count_r <= {`PT_SIZE_W{1'b0}};
			exp_active_buf_r          <= 1'b0;
			exp_active_id_r           <= 30'd0;
			exp_active_row_chunk_count_r <= {`PT_SIZE_W{1'b0}};
			exp_next_row_idx_r        <= {M_AW{1'b0}};
			exp_fetch_row_idx_r       <= {M_AW{1'b0}};
			exp_fill_count_r          <= {EXP_ROW_FILL_W{1'b0}};
			exp_beat_data_r           <= {M_EXPORT_LANES*DATA_WIDTH{1'b0}};
			exp_beat_strb_r           <= {M_EXPORT_LANES*DATA_WIDTH/8{1'b0}};
			exp_beat_valid_r          <= 1'b0;
			exp_beat_last_r           <= 1'b0;
			exp_row_fetch_pending_r   <= 1'b0;
		end else begin
			md_cmd_resp_valid   <= 1'b0;
			md_cmd_irq          <= 1'b0;
			md_async_resp_valid <= 1'b0;
			md_async_irq        <= 1'b0;
			fill_done_valid     <= 1'b0;
			a_mem_wr_en         <= 1'b0;
			a_mem_wr_mask       <= {GEMM_X_DIM{1'b0}};
			b_mem_wr_en         <= 1'b0;
			b_mem_wr_mask       <= {GEMM_Y_DIM{1'b0}};
			csr_a_base_lo_we    <= 1'b0;
			csr_a_base_hi_we    <= 1'b0;
			csr_b_base_lo_we    <= 1'b0;
			csr_b_base_hi_we    <= 1'b0;
			csr_quant_commit_we <= 1'b0;
			fill_recv_count_r   <= fill_recv_count_n;
			m_buf_state0_r      <= m_buf_state0_n;
			m_buf_state1_r      <= m_buf_state1_n;
			next_wr_buf_r       <= next_wr_buf_n;
			exp_req_buf_r       <= exp_req_buf_n;
			exp_req_id_r        <= exp_req_id_n;
			exp_req_row_chunk_count_r <= exp_req_row_chunk_count_n;
			exp_active_buf_r    <= exp_active_buf_n;
			exp_active_id_r     <= exp_active_id_n;
			exp_active_row_chunk_count_r <= exp_active_row_chunk_count_n;
			exp_next_row_idx_r  <= exp_next_row_idx_n;
			exp_fetch_row_idx_r <= exp_fetch_row_idx_n;
			exp_fill_count_r    <= exp_fill_count_n;
			exp_beat_data_r     <= exp_beat_data_n;
			exp_beat_strb_r     <= exp_beat_strb_n;
			exp_beat_valid_r    <= exp_beat_valid_n;
			exp_beat_last_r     <= exp_beat_last_n;
			exp_row_fetch_pending_r <= exp_row_fetch_pending_n;

			if (md_cmd_valid && md_cmd_ready) begin
				case (md_cmd_kind)
					MEM_KIND_CFG: begin
						csr_cfg_wdata16 <= md_cmd_inst[15:0];
						case (md_cmd_inst[27:24])
							`PT_CFG_A_BASE_LO: csr_a_base_lo_we <= 1'b1;
							`PT_CFG_A_BASE_HI: csr_a_base_hi_we <= 1'b1;
							`PT_CFG_B_BASE_LO: csr_b_base_lo_we <= 1'b1;
							`PT_CFG_B_BASE_HI: csr_b_base_hi_we <= 1'b1;
							default: begin end
						endcase
						md_cmd_resp       <= pack_resp(1'b0, 1'b0, md_cmd_id);
						md_cmd_resp_valid <= 1'b1;
					end
					MEM_KIND_REJECT: begin
						md_cmd_resp       <= pack_resp(1'b1, 1'b0, md_cmd_id);
						md_cmd_resp_valid <= 1'b1;
						md_cmd_irq        <= 1'b1;
					end
					MEM_KIND_QCFG_HDR: begin
						if (!qcfg_hdr_ok || qcfg_hdr_err || (qcfg_hdr_cnt == {QCFG_CNT_W{1'b0}})) begin
							md_cmd_resp       <= pack_resp(1'b1, 1'b0, md_cmd_id);
							md_cmd_resp_valid <= 1'b1;
							md_cmd_irq        <= 1'b1;
						end else begin
							qcfg_active_id_r        <= md_cmd_id;
							qcfg_expect_cnt_r       <= qcfg_hdr_cnt;
							qcfg_recv_cnt_r         <= {QCFG_CNT_W{1'b0}};
							qcfg_shadow_mode_r      <= cmd_qcfg_gran;
							qcfg_shadow_inv_scale_r <= csr_quant_inv_scale;
						end
					end
					MEM_KIND_QCFG_PAYLOAD: begin
						if (qcfg_expect_cnt_r == {QCFG_CNT_W{1'b0}}) begin
							md_cmd_resp       <= pack_resp(1'b1, 1'b0, md_cmd_id);
							md_cmd_resp_valid <= 1'b1;
							md_cmd_irq        <= 1'b1;
						end else if (md_cmd_id != qcfg_active_id_r) begin
							md_cmd_resp       <= pack_resp(1'b1, 1'b0, qcfg_active_id_r);
							md_cmd_resp_valid <= 1'b1;
							md_cmd_irq        <= 1'b1;
							qcfg_expect_cnt_r <= {QCFG_CNT_W{1'b0}};
							qcfg_recv_cnt_r   <= {QCFG_CNT_W{1'b0}};
						end else begin
							qcfg_shadow_inv_scale_r[qcfg_recv_cnt_r*32 +: 32] <= md_cmd_inst;
							if ((qcfg_recv_cnt_r + 1'b1) >= qcfg_expect_cnt_r) begin
								csr_quant_mode_wdata <= qcfg_shadow_mode_r;
									for (ri = 0; ri < MAX_DIM; ri = ri + 1) begin
										if (ri == qcfg_recv_cnt_r) begin
										csr_quant_inv_scale_wdata[ri*32 +: 32] <= md_cmd_inst;
									end else begin
										csr_quant_inv_scale_wdata[ri*32 +: 32] <= qcfg_shadow_inv_scale_r[ri*32 +: 32];
									end
								end
								csr_quant_commit_we <= 1'b1;
								md_cmd_resp         <= pack_resp(1'b0, 1'b0, qcfg_active_id_r);
								md_cmd_resp_valid   <= 1'b1;
								qcfg_expect_cnt_r   <= {QCFG_CNT_W{1'b0}};
								qcfg_recv_cnt_r     <= {QCFG_CNT_W{1'b0}};
							end else begin
								qcfg_recv_cnt_r <= qcfg_recv_cnt_r + 1'b1;
							end
						end
					end
					default: begin end
				endcase
			end

			if ((fill_state_r == FILL_IDLE) && fill_req_valid && fill_req_ready) begin
				fill_kind_r       <= fill_req_kind;
				fill_id_r         <= fill_req_id;
				fill_local_base_r <= fill_req_local_base;
				fill_len_r        <= fill_req_len;
				fill_m_tiles_r    <= fill_req_m_tiles;
				fill_n_tiles_r    <= fill_req_n_tiles;
				fill_k_tiles_r    <= fill_req_k_tiles;
				fill_buf_sel_r    <= fill_req_local_base[`PT_LOCAL_BUF_BIT];
					fill_row_base_r   <= (fill_req_kind == `PT_DMA_KIND_A) ?
					                     fill_req_a_row_base :
					                     fill_req_b_row_base;
			end

			if (fill_state_r == FILL_RECV) begin
				if (dma_error || fill_tuser_mismatch) begin
					fill_done_valid <= 1'b1;
					fill_done_kind  <= fill_kind_r;
					fill_done_id    <= fill_id_r;
					fill_done_err   <= 1'b1;
				end else if (s_axis_tvalid) begin
					if (fill_is_a) begin
						a_mem_wr_en   <= 1'b1;
						a_mem_wr_buf  <= fill_buf_sel_r;
						a_mem_wr_addr <= fill_row_base_r[A_AW-1:0]
						                 + fill_a_m_tile_row_offset[A_AW-1:0]
						                 + fill_a_col[A_AW-1:0];
						a_mem_wr_data <= {GEMM_X_DIM*DATA_WIDTH{1'b0}};
							for (fi = 0; fi < GEMM_X_DIM; fi = fi + 1) begin
								if ((fi >= fill_a_row_base_int) &&
								    (fi < (fill_a_row_base_int + A_LOAD_LANES)) &&
								    ((fi - fill_a_row_base_int) < fill_a_valid_elems_int)) begin
									a_mem_wr_mask[fi] <= 1'b1;
									a_mem_wr_data[fi*DATA_WIDTH +: DATA_WIDTH] <= s_axis_tdata[(fi - fill_a_row_base_int)*DATA_WIDTH +: DATA_WIDTH];
								end
							end
					end else if (fill_is_bc) begin
						b_mem_wr_en   <= 1'b1;
						b_mem_wr_buf  <= fill_buf_sel_r;
						b_mem_wr_addr <= fill_row_base_r[B_AW-1:0]
						                 + fill_b_n_tile_row_offset[B_AW-1:0]
						                 + fill_b_row[B_AW-1:0];
						b_mem_wr_data <= {GEMM_Y_DIM*DATA_WIDTH{1'b0}};
							for (fi = 0; fi < GEMM_Y_DIM; fi = fi + 1) begin
								if ((fi >= fill_b_col_base_int) &&
								    (fi < (fill_b_col_base_int + B_LOAD_LANES)) &&
								    ((fi - fill_b_col_base_int) < fill_b_valid_elems_int)) begin
									b_mem_wr_mask[fi] <= 1'b1;
									b_mem_wr_data[fi*DATA_WIDTH +: DATA_WIDTH] <= s_axis_tdata[(fi - fill_b_col_base_int)*DATA_WIDTH +: DATA_WIDTH];
								end
							end
					end
						if ((fill_recv_count_r + fill_beat_elems_size) >= fill_len_r) begin
						fill_done_valid <= 1'b1;
						fill_done_kind  <= fill_kind_r;
						fill_done_id    <= fill_id_r;
						fill_done_err   <= 1'b0;
					end
				end
			end

			if (ce_resp_valid) begin
				if (!ce_resp[31]) begin
					if (ce_resp[30]) begin
						m_buf_id1_r    <= ce_resp[29:0];
						m_buf1_single_output_r <= ce_resp_single_output;
						m_buf1_row_chunk_count_r <= ce_resp_row_chunk_count;
					end else begin
						m_buf_id0_r    <= ce_resp[29:0];
						m_buf0_single_output_r <= ce_resp_single_output;
						m_buf0_row_chunk_count_r <= ce_resp_row_chunk_count;
					end
				end
			end

			case (exp_state_r)
				EXP_IDLE: begin
					if (exp_has_ready) begin
					end
				end
				EXP_REQ: begin
					if (m_dma_req_ready) begin
					end
				end
				EXP_STREAM: begin
					if (exp_prime_req) begin
					end else if (exp_fire) begin
					end
				end
				EXP_WAIT_DONE: begin
					if (m_dma_done || m_dma_error) begin
						if (m_dma_error) begin
							md_async_resp       <= pack_resp(1'b1, exp_active_buf_r, {2'b00, exp_active_id_r});
							md_async_resp_valid <= 1'b1;
							md_async_irq        <= 1'b1;
						end
					end
				end
				default: begin end
			endcase
		end
	end

endmodule
